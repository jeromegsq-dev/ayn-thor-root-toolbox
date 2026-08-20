/*
 * nsofeed - publish the NSO GameCube pad as an ordinary evdev gamepad.
 *
 * The pad speaks a proprietary Nintendo GATT protocol, so it can only be read
 * from inside the app: nothing in the kernel or in Android's input stack knows
 * what it is. That leaves the input stranded in Dart, useful to the launcher and
 * to nothing else — which is the wrong half, since the point of a launcher is
 * the games it starts.
 *
 * So the app pipes each report here and this re-emits it on a uinput node.
 * gpmerge then picks it up the way it picks up any other pad, and the NSO gets
 * the merge, the profiles and the shortcuts for free: to everything downstream
 * it is simply another controller that appeared.
 *
 * Deliberately dumb. It holds no state beyond the last report and makes no
 * mapping decisions — gpmerge already owns all of that, and duplicating it here
 * would mean two places to change whenever a button moves.
 *
 * Input, one line per report, decimal:
 *
 *     <buttons> <lx> <ly> <rx> <ry> <lt> <rt>
 *
 * with buttons a bitmask of the NSO_* bits below, sticks 0..4095 centred near
 * 2048, and triggers 0..255. A blank line is a keepalive and changes nothing.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>

/*
 * Not "AYN Unified Gamepad": gpmerge refuses to read a device by that name, to
 * keep from merging its own output back into itself.
 */
#define VDEV_NAME "NSO GameCube Controller"
/*
 * The pad's real USB ids. Nothing downstream keys off them — gpmerge matches on
 * name and Android never sees this node at all — but a wrong pair would be a
 * lie in `getevent -i` for no gain.
 */
#define VDEV_VENDOR 0x057e
#define VDEV_PRODUCT 0x2073
#define VDEV_VERSION 0x0100

/*
 * Button bits.
 *
 * The app packs report bytes 4, 5 and 6 into one word as `b4<<16 | b5<<8 | b6`,
 * so these are written per source byte rather than as flat indices — that way
 * they can be read straight against the byte layout instead of being arithmetic
 * anyone has to redo.
 *
 * That layout — and the fact that it is bytes 4/5/6 at all, not 2/3/4 — came
 * from pulling raw notify hex off the real pad button by button rather than
 * from either reference implementation: neither's table matches this unit's
 * firmware. Bytes 0-2 are a rolling per-report counter that looks like button
 * noise if you don't know to skip it.
 *
 * R/Z, L/ZL and CAPTURE/C were briefly crossed with each other — an in-app
 * wizard that holds each control for three seconds and watches for the one
 * bit that moves caught what a hand-typed hex dump did not, since a rushed
 * capture session is exactly where two adjacent presses swap labels.
 */
#define B2(n) (1u << (16 + (n)))
#define B3(n) (1u << (8 + (n)))
#define B4(n) (1u << (n))

/* Byte 0x04 — face buttons, the right shoulder and Z. */
#define NSO_Y B2(0)
#define NSO_X B2(1)
#define NSO_B B2(2)
#define NSO_A B2(3)
/* bits 4-5 unused — nothing on the pad set them in any capture. */
#define NSO_Z B2(6) /* the small extra shoulder above R, no analog travel */
#define NSO_R B2(7) /* the click at the bottom of the analog trigger's travel */

/* Byte 0x05 — system buttons. GR and GL are Pro Controller paddles this pad
 * does not have, so they go unmapped like the other unused bits here. */
#define NSO_START B3(1)
#define NSO_HOME B3(4)
#define NSO_C B3(5) /* the GameChat button */
#define NSO_CAPTURE B3(6)

/* Byte 0x06 — d-pad, the left shoulder and ZL. */
#define NSO_DOWN B4(0)
#define NSO_UP B4(1)
#define NSO_RIGHT B4(2)
#define NSO_LEFT B4(3)
#define NSO_ZL B4(6) /* the small extra shoulder above L, no analog travel */
#define NSO_L B4(7) /* the click at the bottom of the analog trigger's travel */

/* Stick and trigger scales, from the pad's own resolution. */
#define STICK_CENTRE 2048
/*
 * Seed half-width for a stick that has not yet been pushed far in a given
 * direction. Real full deflection measured well above this (out to ~3234 on
 * one axis in one capture) so it never clips a real push short — it only
 * keeps idle jitter, a few units wide, from reading as a meaningful fraction
 * of travel before the range below has had a chance to learn the real one.
 */
#define STICK_SEED_HALF 900
#define TRIGGER_MAX 255

struct button_map {
	unsigned int bit;
	int code;
};

/*
 * Ranges copied from gpmerge's own output pad rather than chosen here. SDL
 * numbers axes by position rather than by name, so a device that declares a
 * different set — or the same set in a different order — shifts every axis
 * after the difference. Matching gpmerge means a game reads the NSO exactly as
 * it reads the built-in pad.
 */
/*
 * Names are kept: A is A, not "the bottom face button". A GameCube pad's face
 * layout is its own thing — A large in the middle, B to its left — and any
 * attempt to rotate it into an Xbox diamond makes one game right and the next
 * one wrong. gpmerge profiles are the place to disagree with this.
 *
 * L and R carry their analog travel on ABS_BRAKE/ABS_GAS as well; these are the
 * clicks at the end of it. Z is the extra shoulder above R and ZL its mirror
 * above L — this unit has both, unlike a stock GameCube pad — which is why
 * they land on the trigger buttons rather than face ones. There are no stick
 * clicks to map — the pad has none.
 */
static const struct button_map buttons[] = {
	{ NSO_A, BTN_A },
	{ NSO_B, BTN_B },
	{ NSO_X, BTN_X },
	{ NSO_Y, BTN_Y },
	{ NSO_L, BTN_TL },
	{ NSO_R, BTN_TR },
	{ NSO_ZL, BTN_TL2 },
	{ NSO_Z, BTN_TR2 },
	{ NSO_C, BTN_C },
	{ NSO_START, BTN_START },
	/*
	 * Not BTN_SELECT, however much Capture looks like a Select button:
	 * BTN_SELECT is the modifier every shortcut combo in gpmerge.conf is built
	 * on. Sending it turned the whole pad into a shortcut layer — each face
	 * button changing brightness or volume instead of reaching the game, and
	 * the modifier itself held back on the way. Map it to Select in a profile
	 * if that is really wanted; the default should not booby-trap the pad.
	 */
	{ NSO_CAPTURE, KEY_BACK },
	{ NSO_HOME, BTN_MODE },
	{ NSO_UP, BTN_DPAD_UP },
	{ NSO_DOWN, BTN_DPAD_DOWN },
	{ NSO_LEFT, BTN_DPAD_LEFT },
	{ NSO_RIGHT, BTN_DPAD_RIGHT },
};

struct axis_def {
	int code;
	int min, max, fuzz, flat;
};

static const struct axis_def axes[] = {
	{ ABS_X, -32768, 32767, 16, 128 },
	{ ABS_Y, -32768, 32767, 16, 128 },
	{ ABS_Z, -32768, 32767, 16, 128 },
	{ ABS_RZ, -32768, 32767, 16, 128 },
	/* Analog trigger travel. The AYN pad has none — its triggers are digital —
	 * but gpmerge's output declares these anyway, so a GameCube pad's real
	 * analog travel survives to games that ask for it. */
	{ ABS_GAS, 0, 1023, 0, 0 },
	{ ABS_BRAKE, 0, 1023, 0, 0 },
	/*
	 * No ABS_HAT0X/Y: the AYN pad reports its d-pad as BTN_DPAD_* and declares
	 * no hat at all. Sending both shapes would move a menu two steps per press
	 * on anything that reads either.
	 */
};

static int ufd = -1;

static void emit(int type, int code, int value)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = value;
	if (write(ufd, &ev, sizeof(ev)) < 0 && errno != EAGAIN)
		fprintf(stderr, "nsofeed: write: %s\n", strerror(errno));
}

/*
 * How far this axis has actually been seen to travel on each side of centre —
 * distinct per axis and per direction, since nothing says a stick is wired
 * symmetrically. Starts at the seed half-width and only ever widens.
 */
struct stick_range {
	int lo, hi; /* raw values, not scaled */
};

/*
 * 0..4095 centred at 2048, to the signed range the output axis declares —
 * scaled against [range]'s *observed* travel rather than the pad's nominal
 * 0..4095, which the stick never actually reaches: full deflection measured
 * out to ~3234 on one axis in one capture, nowhere near either end. A fixed
 * assumption left every push reading short of 100%; this one learns the real
 * ends as it sees them, so the first true full push becomes the new 100% for
 * good.
 *
 * [invert] is for the vertical axes. The pad counts up as the stick goes up,
 * evdev counts up as it goes down, and the two conventions disagree on every
 * pad Nintendo has ever made — without this, forward is backward in every game.
 */
static int to_stick(int raw, int invert, struct stick_range *range)
{
	long scaled;

	if (raw < 0)
		raw = 0;
	if (raw > 4095)
		raw = 4095;

	if (raw < STICK_CENTRE) {
		int span = STICK_CENTRE - range->lo;
		scaled = span > 0 ? -32768L * (STICK_CENTRE - raw) / span : 0;
	} else {
		int span = range->hi - STICK_CENTRE;
		scaled = span > 0 ? 32767L * (raw - STICK_CENTRE) / span : 0;
	}

	/* Widen for next time only after scoring this sample against the range
	 * it was actually measured against — otherwise the very sample that
	 * discovers a new extreme would also be judged against it, reading a
	 * hair short of 100% right when it should be exactly 100%. */
	if (raw < range->lo)
		range->lo = raw;
	if (raw > range->hi)
		range->hi = raw;

	if (invert)
		scaled = -scaled;
	if (scaled < -32768)
		scaled = -32768;
	if (scaled > 32767)
		scaled = 32767;
	return (int)scaled;
}

#define STICK_SEED \
	{ STICK_CENTRE - STICK_SEED_HALF, STICK_CENTRE + STICK_SEED_HALF }
static struct stick_range lx_range = STICK_SEED;
static struct stick_range ly_range = STICK_SEED;
static struct stick_range rx_range = STICK_SEED;
static struct stick_range ry_range = STICK_SEED;

/*
 * Same idea as a stick's [stick_range], but one-sided: [lo] is "released",
 * [hi] is "fully pressed". Seeded a little inside the raw 0..255 nominal
 * range rather than at its ends — measured idle sat around 28..40, not 0, and
 * a full click around 229..237, not 255, so the fixed range this replaced
 * never read either end cleanly: a trigger looked slightly held at rest and
 * never reached 100% pressed.
 */
struct trigger_range {
	int lo, hi;
};

#define TRIGGER_SEED_LO 20
#define TRIGGER_SEED_HI 210
#define TRIGGER_SEED { TRIGGER_SEED_LO, TRIGGER_SEED_HI }
static struct trigger_range lt_range = TRIGGER_SEED;
static struct trigger_range rt_range = TRIGGER_SEED;

static int to_trigger(int raw, struct trigger_range *range)
{
	int span, v;

	if (raw < 0)
		raw = 0;
	if (raw > TRIGGER_MAX)
		raw = TRIGGER_MAX;

	span = range->hi - range->lo;
	v = span > 0 ? (raw - range->lo) * 1023 / span : 0;
	if (v < 0)
		v = 0;
	if (v > 1023)
		v = 1023;

	/* Widened only after scoring this sample, same reasoning as the sticks:
	 * the sample that discovers a new extreme should read as that extreme,
	 * not as a hair short of it. */
	if (raw < range->lo)
		range->lo = raw;
	if (raw > range->hi)
		range->hi = raw;

	return v;
}

static int create_device(void)
{
	struct uinput_setup us;
	struct uinput_abs_setup as;
	size_t i;
	int fd;

	/* Read-write: force-feedback upload/erase requests and play events from
	 * gpmerge arrive as reads on this same fd, the one that created the
	 * device — uinput has no separate channel for them. */
	fd = open("/dev/uinput", O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		fprintf(stderr, "nsofeed: open /dev/uinput: %s\n", strerror(errno));
		return -1;
	}

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	ioctl(fd, UI_SET_EVBIT, EV_FF);
	ioctl(fd, UI_SET_FFBIT, FF_RUMBLE);

	for (i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++)
		ioctl(fd, UI_SET_KEYBIT, buttons[i].code);

	for (i = 0; i < sizeof(axes) / sizeof(axes[0]); i++) {
		ioctl(fd, UI_SET_ABSBIT, axes[i].code);
		memset(&as, 0, sizeof(as));
		as.code = axes[i].code;
		as.absinfo.minimum = axes[i].min;
		as.absinfo.maximum = axes[i].max;
		as.absinfo.fuzz = axes[i].fuzz;
		as.absinfo.flat = axes[i].flat;
		ioctl(fd, UI_ABS_SETUP, &as);
	}

	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_BLUETOOTH;
	us.id.vendor = VDEV_VENDOR;
	us.id.product = VDEV_PRODUCT;
	us.id.version = VDEV_VERSION;
	snprintf(us.name, sizeof(us.name), "%s", VDEV_NAME);
	us.ff_effects_max = 1; /* on/off is all the pad's rumble motor takes */

	if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		fprintf(stderr, "nsofeed: creating uinput device: %s\n", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

/*
 * Locks the node to root only.
 *
 * Without this Android's EventHub opens it too — system_server is in group
 * input — and the pad arrives twice: once merged through gpmerge, once raw
 * beside it, so every press counts double and the merge it was added to is
 * bypassed. gpmerge runs as root and is unaffected.
 */
static void restrict_node(void)
{
	char sysname[64] = { 0 };
	char dir[128];
	char path[128] = { 0 };
	struct dirent *de;
	struct stat st;
	DIR *d;
	int i;

	if (ioctl(ufd, UI_GET_SYSNAME(sizeof(sysname)), sysname) < 0) {
		fprintf(stderr, "nsofeed: UI_GET_SYSNAME: %s\n", strerror(errno));
		return;
	}
	snprintf(dir, sizeof(dir), "/sys/class/input/%s", sysname);
	d = opendir(dir);
	if (!d) {
		fprintf(stderr, "nsofeed: opendir %s: %s\n", dir, strerror(errno));
		return;
	}
	/* The event node's number is not the input device's; sysfs holds the pairing. */
	while ((de = readdir(d))) {
		if (strncmp(de->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		break;
	}
	closedir(d);

	if (!path[0]) {
		fprintf(stderr, "nsofeed: could not locate our node under %s\n", dir);
		return;
	}

	/* sysfs is populated as soon as UI_DEV_CREATE returns, but ueventd creates
	 * the /dev node a moment later. Without this wait the chmod below lands on
	 * nothing and the pad arrives twice. */
	for (i = 0; i < 100; i++) {
		if (stat(path, &st) == 0)
			break;
		usleep(20 * 1000);
	}
	if (i == 100) {
		fprintf(stderr, "nsofeed: %s never appeared; cannot lock it down\n", path);
		return;
	}

	if (chown(path, 0, 0) < 0 || chmod(path, 0600) < 0)
		fprintf(stderr, "nsofeed: locking %s: %s\n", path, strerror(errno));
	else
		fprintf(stderr, "nsofeed: %s is %s, root only\n", VDEV_NAME, path);
}

/*
 * Handles one event read from our own uinput fd's force-feedback direction —
 * gpmerge uploading or erasing the one effect it will ever ask for, or
 * playing or stopping it. Accepted unconditionally: there is nothing to
 * negotiate when only one effect, on/off, is on offer.
 *
 * A play/stop is not turned into a BLE write here — this process holds no
 * GATT connection, only stdin/stdout to the app that does. It is printed to
 * stdout instead, the same channel "feed: ..." log lines already travel, for
 * the app's reader thread to turn into the actual write.
 */
static void handle_ff_event(const struct input_event *ev)
{
	struct uinput_ff_upload up;
	struct uinput_ff_erase er;

	if (ev->type == EV_UINPUT && ev->code == UI_FF_UPLOAD) {
		memset(&up, 0, sizeof(up));
		up.request_id = ev->value;
		if (ioctl(ufd, UI_BEGIN_FF_UPLOAD, &up) < 0)
			return;
		up.retval = 0;
		ioctl(ufd, UI_END_FF_UPLOAD, &up);
	} else if (ev->type == EV_UINPUT && ev->code == UI_FF_ERASE) {
		memset(&er, 0, sizeof(er));
		er.request_id = ev->value;
		if (ioctl(ufd, UI_BEGIN_FF_ERASE, &er) < 0)
			return;
		er.retval = 0;
		ioctl(ufd, UI_END_FF_ERASE, &er);
	} else if (ev->type == EV_FF) {
		printf("rumble %d\n", ev->value != 0);
		fflush(stdout);
	}
}

int main(void)
{
	char line[256];
	unsigned int prev_buttons = 0;
	int first = 1;
	struct pollfd pfd[2];

	ufd = create_device();
	if (ufd < 0)
		return 1;
	restrict_node();

	/* Line buffered both ways: a report held in a buffer is input not delivered. */
	setvbuf(stdin, NULL, _IOLBF, 0);
	setvbuf(stderr, NULL, _IOLBF, 0);

	/*
	 * stdin alone used to be enough to block on. It no longer is: force
	 * feedback arrives as reads on [ufd], the same fd every EV_ABS/EV_KEY
	 * report is written to, and there is no telling which of the two will
	 * have something next.
	 */
	for (;;) {
		struct input_event evs[16];
		int n;

		pfd[0].fd = STDIN_FILENO;
		pfd[0].events = POLLIN;
		pfd[0].revents = 0;
		pfd[1].fd = ufd;
		pfd[1].events = POLLIN;
		pfd[1].revents = 0;

		if (poll(pfd, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "nsofeed: poll: %s\n", strerror(errno));
			break;
		}

		if (pfd[1].revents & POLLIN) {
			n = read(ufd, evs, sizeof(evs));
			if (n > 0) {
				size_t j;
				for (j = 0; j < n / sizeof(struct input_event); j++)
					handle_ff_event(&evs[j]);
			}
		}

		if (!(pfd[0].revents & POLLIN)) {
			/* stdin closed: the app let go, so take the pad away rather
			 * than leaving a dead node for gpmerge to keep merging. */
			if (pfd[0].revents & (POLLHUP | POLLERR))
				break;
			continue;
		}

		if (!fgets(line, sizeof(line), stdin))
			break; /* EOF */

		{
			unsigned int b;
			int lx, ly, rx, ry, lt, rt;
			size_t i;

			if (sscanf(line, "%u %d %d %d %d %d %d", &b, &lx, &ly, &rx, &ry, &lt, &rt) != 7)
				continue;

			for (i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) {
				unsigned int bit = buttons[i].bit;
				if (first || ((prev_buttons ^ b) & bit))
					emit(EV_KEY, buttons[i].code, (b & bit) ? 1 : 0);
			}

			emit(EV_ABS, ABS_X, to_stick(lx, 0, &lx_range));
			emit(EV_ABS, ABS_Y, to_stick(ly, 1, &ly_range));
			/* Z and RZ, not RX and RY: the right stick sits there on these
			 * pads, which is the convention gpmerge's output and the AYN
			 * key layout are both written for. */
			emit(EV_ABS, ABS_Z, to_stick(rx, 0, &rx_range));
			emit(EV_ABS, ABS_RZ, to_stick(ry, 1, &ry_range));
			emit(EV_ABS, ABS_GAS, to_trigger(rt, &rt_range));
			emit(EV_ABS, ABS_BRAKE, to_trigger(lt, &lt_range));

			emit(EV_SYN, SYN_REPORT, 0);
			prev_buttons = b;
			first = 0;
		}
	}

	ioctl(ufd, UI_DEV_DESTROY);
	close(ufd);
	return 0;
}
