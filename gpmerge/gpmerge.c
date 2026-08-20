/*
 * gpmerge - merge every gamepad on an AYN Thor into a single virtual controller.
 *
 * Android numbers controllers per evdev device in arrival order, so the built-in
 * pad is always player 1 and anything connected later becomes player 2. Games
 * that bind a player to a controller number (or that only read joystick index 0,
 * as SDL ports like sm64ex do) then ignore the external pad.
 *
 * This daemon reads every gamepad and re-emits the union on one uinput device.
 * It deliberately does NOT grab or unlink anything: com.odin.mapping owns
 * /dev/uinput and creates all the AYN virtual pads, and it recreates a pad as
 * soon as its node vanishes or its reads dry up. Fighting it produces exactly
 * the intermittent behaviour we are trying to remove.
 *
 * Two cooperating pieces make the merge visible to Android and only to Android:
 *
 *   1. The source pads are listed in /vendor/etc/excluded-input-devices.xml, so
 *      Android's EventHub skips them. Their nodes stay untouched, so the AYN
 *      mapper keeps working exactly as before.
 *   2. Our own node is set to 0660 root:input. system_server belongs to group
 *      input and sees it; com.odin.mapping runs as uid system *without* group
 *      input, so it cannot open it and therefore never clones it.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Must not appear in excluded-input-devices.xml, or Android would skip us too. */
#define VDEV_NAME "AYN Unified Gamepad"
/*
 * Borrow the AYN pad's ids so Android applies Vendor_2020_Product_0111.kl, the
 * layout written for these very controllers. An earlier attempt used Microsoft
 * ids (045e:02d1), which pulled in the Xbox 360 layout and its older axis
 * convention: it maps ABS_Z/ABS_RZ to the triggers, so the right stick drove
 * LTRIGGER/RTRIGGER while the real triggers landed on GENERIC_1/GENERIC_2, and
 * it maps neither the system keys nor the d-pad buttons we forward.
 * Only the name distinguishes us from the AYN pads, and matching is by name.
 */
#define VDEV_VENDOR 0x2020
#define VDEV_PRODUCT 0x0111
#define VDEV_VERSION 0x0100

#define AYN_VENDOR 0x2020 /* AYN's virtual pads, produced by com.odin.mapping */
#define AID_INPUT 1004

#define CONFIG_PATH "/data/adb/modules/gpmerge/gpmerge.conf"

#define MAX_SRC 16
#define MAX_PROFILES 12
#define MAX_SHORTCUTS 16
/* Buttons in one combo. Three is already awkward to hold on a handheld. */
#define MAX_COMBO 4
#define MAX_CMD 384

/*
 * A combo's first button does double duty, so a modifier need not be a button
 * the game has no use for.
 *
 * Its press is held back rather than forwarded. Let go quickly and on its own
 * and it was a tap: the press goes out then, as a pulse, and the game sees a
 * normal button. Hold it and the pad is on a second layer — every other button
 * pressed while it is down is withheld too, whether or not it completes a
 * combo, so a macro never leaks half of itself into the game.
 */
#define TAP_PULSE_MS 50
#define TAP_MAX_MS 500
#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define test_bit(bit, arr) ((arr[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

/*
 * A stick pushed past a threshold counts as a combo button of its own, so
 * "hold the right stick down" can drive a shortcut exactly like a real
 * button — brightness and volume being the obvious use, since neither stick
 * is free on every game. Borrows the BTN_TRIGGER_HAPPY range: codes reserved
 * by the kernel for exactly this kind of made-up button, never produced by a
 * real pad and never accepted by `button`/`key` directives (they are absent
 * from key_names[]), so they cannot collide with anything a profile targets.
 */
#define PB_LSTICK_LEFT  BTN_TRIGGER_HAPPY1
#define PB_LSTICK_RIGHT BTN_TRIGGER_HAPPY2
#define PB_LSTICK_UP    BTN_TRIGGER_HAPPY3
#define PB_LSTICK_DOWN  BTN_TRIGGER_HAPPY4
#define PB_RSTICK_LEFT  BTN_TRIGGER_HAPPY5
#define PB_RSTICK_RIGHT BTN_TRIGGER_HAPPY6
#define PB_RSTICK_UP    BTN_TRIGGER_HAPPY7
#define PB_RSTICK_DOWN  BTN_TRIGGER_HAPPY8

/*
 * Percent of the axis's half-span. Past ON it is "held" for [shortcuts]; back
 * under OFF releases it. The gap between the two is hysteresis: sitting a
 * stick right on one fixed threshold would chatter the shortcut on and off.
 */
#define STICK_ON 90
#define STICK_OFF 75

/*
 * Per-pad remapping. Both pads reach us through the AYN mapper and therefore
 * report the same 2020:0111 id, so profiles are matched on the device *name*.
 * A code mapped to -1 is dropped entirely.
 */
struct remap {
	short key[KEY_CNT];
	short axis[ABS_CNT];
	/*
	 * A button can drive an axis instead of another button, which is how a
	 * d-pad becomes a stick: the axis a key pushes, -1 for none, and which
	 * end it pushes it to.
	 */
	short key_axis[KEY_CNT];
	signed char key_dir[KEY_CNT];
	unsigned char invert[ABS_CNT];
	int deadzone[ABS_CNT]; /* in output units, around the axis centre */
};

struct profile {
	char match[128]; /* glob against the device name */
	struct remap map;
};

struct src {
	int fd;
	char path[64];
	char name[128];
	unsigned short vendor, product;
	dev_t rdev;
	unsigned long keystate[NBITS(KEY_CNT)]; /* buttons this pad holds down */
	struct input_absinfo abs[ABS_CNT];
	struct remap map;
	/*
	 * -1 until an FF_RUMBLE effect has been uploaded to this source. One
	 * effect is all any of these pads need — rumble here is on/off, not a
	 * waveform — so it is uploaded once at merge time and reused for every
	 * play request for as long as the pad stays merged.
	 */
	int ff_id;
};

static struct src srcs[MAX_SRC];
static int nsrc;
static int out_fd = -1;
static char own_path[64];
static dev_t own_rdev;
/*
 * A button combination that runs a command instead of reaching the game. A
 * token may also be a stick pushed past STICK_ON — see stick_names[].
 *
 * Matched on the merged pad's own codes, after remapping, so a combo means the
 * same thing whichever controller it is pressed on. The daemon is the only
 * thing here that sees input while a game is in front, which is why this lives
 * in it rather than in the app.
 */
struct shortcut {
	int codes[MAX_COMBO];
	int ncodes;
	char cmd[MAX_CMD];
	int fired; /* held since it last ran, so holding does not repeat it */
};

static int key_held[KEY_CNT]; /* how many pads hold each button */

/*
 * How many buttons are pushing each axis to each end, counted rather than
 * flagged: with both ends held the stick belongs at rest, and letting one go
 * must leave it pushed the other way rather than centred.
 */
static int axis_push[ABS_CNT][2]; /* [0] towards min, [1] towards max */


/* Whether the merged pad is currently holding a code down because we sent it. */
static int emitted[KEY_CNT];
/* When a deferred modifier went down, 0 when it is not being held back. */
static long long defer_since[KEY_CNT];
/* Something happened while it was held, so it was a modifier, not a tap. */
static int defer_spent[KEY_CNT];
/* How many modifiers are held: above zero, the pad is on its second layer. */
static int mods_down;
/* When a tap's release is due, 0 when no pulse is in flight. */
static long long tap_until[KEY_CNT];
static int taps_pending;

static struct profile profiles[MAX_PROFILES];
static struct shortcut shortcuts[MAX_SHORTCUTS];
static int nshortcuts;
static int nprofiles;
static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t reload_cfg;
static int opt_verbose;
static int opt_list;  /* print the merged pads and exit */
static int opt_watch; /* stream events for the configuration UI */
static const char *cfg_path = CONFIG_PATH;

/* Fixed capability set, so a hotplugged pad never needs caps we did not declare. */
static const int out_keys[] = {
	BTN_A, BTN_B, BTN_C, BTN_X, BTN_Y, BTN_Z,
	BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,
	BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR,
	BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT,
	/* The AYN pads route their system buttons through plain key codes rather
	 * than BTN_MODE. A code we do not declare here is silently dropped by the
	 * kernel when we write it, which is what killed the Home button. */
	KEY_HOME, KEY_BACK, KEY_APPSELECT, KEY_VOLUMEUP, KEY_VOLUMEDOWN,
};

struct axis_def {
	int code;
	int min, max, fuzz, flat;
};

/*
 * Declare an axis only if something can drive it, and give it the range of what
 * it carries.
 *
 * Both rules exist because of what reads them. SDL — which is most ports on
 * this device — does not look axes up by name: it takes Android's motion range
 * list, drops the hats, and numbers the rest in order, then applies its default
 * mapping of a0/a1 to the left stick, a2/a3 to the right one and a4/a5 to the
 * triggers. An axis we declare but never write still takes its slot and shifts
 * every axis after it. ABS_RX and ABS_RY used to sit between Z and RZ for the
 * sake of profiles that might target them, and nothing on these pads produces
 * them: the right stick's vertical fell through to a5, so pushing the stick
 * down pulled the right trigger, and the real triggers landed past the end of
 * the mapping.
 *
 * The ranges say what each axis *is*: a signed range means "stick, centred at
 * zero", an unsigned one "trigger, released at zero". Z and RZ carry the right
 * stick on these pads — the modern evdev convention, the one
 * Vendor_2020_Product_0111.kl is written for — so they are signed like X and Y.
 * Declaring them 0..1023 put a centred stick's rest position at 511, which read
 * as two triggers held halfway down.
 */
static const struct axis_def out_axes[] = {
	{ ABS_X,        -32768, 32767, 16, 128 },
	{ ABS_Y,        -32768, 32767, 16, 128 },
	{ ABS_Z,        -32768, 32767, 16, 128 },
	{ ABS_RZ,       -32768, 32767, 16, 128 },
	{ ABS_GAS,           0,  1023,  0,   0 },
	{ ABS_BRAKE,         0,  1023,  0,   0 },
	{ ABS_HAT0X,        -1,     1,  0,   0 },
	{ ABS_HAT0Y,        -1,     1,  0,   0 },
};

struct code_name {
	const char *name;
	int code;
};

/* Note the Linux naming trap: BTN_X is the *north* face button and BTN_Y the
 * *west* one. Both spellings are accepted so a profile can be written either
 * way without surprises. */
static const struct code_name key_names[] = {
	{ "BTN_A", BTN_A }, { "BTN_SOUTH", BTN_SOUTH },
	{ "BTN_B", BTN_B }, { "BTN_EAST", BTN_EAST },
	{ "BTN_C", BTN_C },
	{ "BTN_X", BTN_X }, { "BTN_NORTH", BTN_NORTH },
	{ "BTN_Y", BTN_Y }, { "BTN_WEST", BTN_WEST },
	{ "BTN_Z", BTN_Z },
	{ "BTN_TL", BTN_TL }, { "BTN_TR", BTN_TR },
	{ "BTN_TL2", BTN_TL2 }, { "BTN_TR2", BTN_TR2 },
	{ "BTN_SELECT", BTN_SELECT }, { "BTN_START", BTN_START },
	{ "BTN_MODE", BTN_MODE },
	{ "BTN_THUMBL", BTN_THUMBL }, { "BTN_THUMBR", BTN_THUMBR },
	{ "BTN_DPAD_UP", BTN_DPAD_UP }, { "BTN_DPAD_DOWN", BTN_DPAD_DOWN },
	{ "BTN_DPAD_LEFT", BTN_DPAD_LEFT }, { "BTN_DPAD_RIGHT", BTN_DPAD_RIGHT },
	{ "KEY_HOME", KEY_HOME }, { "KEY_BACK", KEY_BACK },
	{ "KEY_APPSELECT", KEY_APPSELECT },
	{ "KEY_VOLUMEUP", KEY_VOLUMEUP }, { "KEY_VOLUMEDOWN", KEY_VOLUMEDOWN },
	{ NULL, 0 },
};

static const struct code_name abs_names[] = {
	{ "ABS_X", ABS_X }, { "ABS_Y", ABS_Y },
	{ "ABS_RX", ABS_RX }, { "ABS_RY", ABS_RY },
	{ "ABS_Z", ABS_Z }, { "ABS_RZ", ABS_RZ },
	{ "ABS_BRAKE", ABS_BRAKE }, { "ABS_GAS", ABS_GAS },
	{ "ABS_HAT0X", ABS_HAT0X }, { "ABS_HAT0Y", ABS_HAT0Y },
	{ NULL, 0 },
};

/*
 * Combo-only pseudo buttons for a stick pushed past STICK_ON — see
 * update_stick_shortcuts(). X/Y carry the left stick, Z/RZ the right one
 * (the modern evdev convention out_axes[] is built for); up and left are
 * each axis's negative side, matching ordinary joystick convention.
 */
static const struct code_name stick_names[] = {
	{ "LSTICK_LEFT", PB_LSTICK_LEFT }, { "LSTICK_RIGHT", PB_LSTICK_RIGHT },
	{ "LSTICK_UP", PB_LSTICK_UP }, { "LSTICK_DOWN", PB_LSTICK_DOWN },
	{ "RSTICK_LEFT", PB_RSTICK_LEFT }, { "RSTICK_RIGHT", PB_RSTICK_RIGHT },
	{ "RSTICK_UP", PB_RSTICK_UP }, { "RSTICK_DOWN", PB_RSTICK_DOWN },
	{ NULL, 0 },
};

static int lookup_code(const struct code_name *tbl, const char *name)
{
	int i;
	for (i = 0; tbl[i].name; i++)
		if (strcasecmp(tbl[i].name, name) == 0)
			return tbl[i].code;
	return -1;
}

static const char *lookup_name(const struct code_name *tbl, int code)
{
	int i;
	for (i = 0; tbl[i].name; i++)
		if (tbl[i].code == code)
			return tbl[i].name;
	return NULL;
}

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static void on_signal(int sig)
{
	if (sig == SIGHUP)
		reload_cfg = 1; /* re-read the profiles without dropping any pad */
	else
		running = 0;
}

static void remap_reset(struct remap *m)
{
	int i;
	for (i = 0; i < KEY_CNT; i++) {
		m->key[i] = (short)i;
		m->key_axis[i] = -1;
		m->key_dir[i] = 0;
	}
	for (i = 0; i < ABS_CNT; i++)
		m->axis[i] = (short)i;
	memset(m->invert, 0, sizeof(m->invert));
	memset(m->deadzone, 0, sizeof(m->deadzone));
}

static char *trim(char *s)
{
	char *end;
	while (*s && isspace((unsigned char)*s))
		s++;
	end = s + strlen(s);
	while (end > s && isspace((unsigned char)end[-1]))
		*--end = '\0';
	return s;
}

static void apply_preset(struct remap *m, const char *preset, int lineno)
{
	if (strcasecmp(preset, "nintendo") == 0) {
		/* Nintendo's face buttons sit where Xbox's B/A and Y/X do. */
		m->key[BTN_SOUTH] = BTN_EAST;
		m->key[BTN_EAST] = BTN_SOUTH;
		m->key[BTN_NORTH] = BTN_WEST;
		m->key[BTN_WEST] = BTN_NORTH;
	} else if (strcasecmp(preset, "xbox") == 0) {
		/* Reference layout: nothing to change. */
	} else {
		logmsg("config:%d: unknown preset '%s' (known: nintendo, xbox)",
		       lineno, preset);
	}
}

/*
 * Config format, one section per pad, matched as a glob on the device name:
 *
 *   [Nintendo Switch Pro Controller]
 *   preset nintendo
 *   button BTN_SELECT = BTN_MODE
 *   axis ABS_RX = ABS_RY
 *   invert ABS_RY
 *   deadzone ABS_X = 2500
 *   button BTN_C = none        # drop this button
 */
/*
 * "BTN_MODE+BTN_DPAD_UP" into codes. Returns 0 if any name is unknown, so a
 * typo disables that one shortcut rather than half of it. A token may also
 * name a stick direction (RSTICK_DOWN and friends, see stick_names[]).
 */
static int parse_combo(char *spec, struct shortcut *sc)
{
	sc->ncodes = 0;
	for (char *tok = strtok(spec, "+"); tok; tok = strtok(NULL, "+")) {
		char *name = trim(tok);
		int code = lookup_code(key_names, name);
		if (code < 0)
			code = lookup_code(stick_names, name);
		if (code < 0 || sc->ncodes >= MAX_COMBO)
			return 0;
		sc->codes[sc->ncodes++] = code;
	}
	return sc->ncodes > 0;
}

static void load_config(void)
{
	char line[512];
	struct profile *cur = NULL;
	FILE *f;
	int lineno = 0;
	int in_shortcuts = 0;

	nprofiles = 0;
	nshortcuts = 0;

	f = fopen(cfg_path, "r");
	if (!f) {
		if (errno != ENOENT)
			logmsg("config: cannot read %s: %s", cfg_path, strerror(errno));
		logmsg("config: no profiles loaded, passing every pad through unchanged");
		return;
	}

	while (fgets(line, sizeof(line), f)) {
		char *s, *hash, *eq, *arg;
		lineno++;

		hash = strchr(line, '#');
		if (hash)
			*hash = '\0';
		s = trim(line);
		if (!*s)
			continue;

		if (*s == '[') {
			char *close = strchr(s, ']');
			if (!close) {
				logmsg("config:%d: missing ']'", lineno);
				continue;
			}
			*close = '\0';
			/* One reserved section name; every other one is a pad glob. */
			in_shortcuts = strcasecmp(trim(s + 1), "shortcuts") == 0;
			if (in_shortcuts) {
				cur = NULL;
				continue;
			}
			if (nprofiles >= MAX_PROFILES) {
				logmsg("config:%d: more than %d profiles, ignoring the rest",
				       lineno, MAX_PROFILES);
				break;
			}
			cur = &profiles[nprofiles++];
			memset(cur, 0, sizeof(*cur));
			snprintf(cur->match, sizeof(cur->match), "%s", trim(s + 1));
			remap_reset(&cur->map);
			continue;
		}

		if (!cur && !in_shortcuts) {
			logmsg("config:%d: directive outside any [section]", lineno);
			continue;
		}

		/* Split "<verb> <operand> [= <value>]". */
		arg = s;
		while (*arg && !isspace((unsigned char)*arg))
			arg++;
		if (*arg)
			*arg++ = '\0';
		arg = trim(arg);
		eq = strchr(arg, '=');
		if (eq) {
			*eq = '\0';
			arg = trim(arg);
			eq = trim(eq + 1);
		}

		if (in_shortcuts) {
			struct shortcut *sc;
			if (strcasecmp(s, "combo") != 0) {
				logmsg("config:%d: unknown directive '%s' in [shortcuts]", lineno, s);
				continue;
			}
			if (!eq || !*eq) {
				logmsg("config:%d: combo without a command", lineno);
				continue;
			}
			if (nshortcuts >= MAX_SHORTCUTS) {
				logmsg("config:%d: more than %d shortcuts, ignoring the rest",
				       lineno, MAX_SHORTCUTS);
				continue;
			}
			sc = &shortcuts[nshortcuts];
			memset(sc, 0, sizeof(*sc));
			if (!parse_combo(arg, sc)) {
				logmsg("config:%d: unknown button in combo", lineno);
				continue;
			}
			snprintf(sc->cmd, sizeof(sc->cmd), "%s", eq);
			nshortcuts++;
			continue;
		}

		if (strcasecmp(s, "preset") == 0) {
			apply_preset(&cur->map, arg, lineno);
		} else if (strcasecmp(s, "button") == 0 || strcasecmp(s, "key") == 0) {
			int from = lookup_code(key_names, arg);
			int to = (eq && strcasecmp(eq, "none") == 0)
					 ? -1
					 : (eq ? lookup_code(key_names, eq) : -2);
			if (from < 0 || to == -2)
				logmsg("config:%d: unknown button in '%s'", lineno, arg);
			else
				cur->map.key[from] = (short)to;
		} else if (strcasecmp(s, "axis") == 0) {
			int from = lookup_code(abs_names, arg);
			int to = (eq && strcasecmp(eq, "none") == 0)
					 ? -1
					 : (eq ? lookup_code(abs_names, eq) : -2);
			if (from < 0 || to == -2)
				logmsg("config:%d: unknown axis in '%s'", lineno, arg);
			else
				cur->map.axis[from] = (short)to;
		} else if (strcasecmp(s, "invert") == 0) {
			int code = lookup_code(abs_names, arg);
			if (code < 0)
				logmsg("config:%d: unknown axis '%s'", lineno, arg);
			else
				cur->map.invert[code] = 1;
		} else if (strcasecmp(s, "deadzone") == 0) {
			int code = lookup_code(abs_names, arg);
			if (code < 0 || !eq)
				logmsg("config:%d: bad deadzone directive", lineno);
			else
				cur->map.deadzone[code] = atoi(eq);
		} else {
			logmsg("config:%d: unknown directive '%s'", lineno, s);
		}
	}
	fclose(f);
	logmsg("config: %d profile(s) loaded from %s", nprofiles, cfg_path);
}

/* Bind the first profile whose glob matches this pad's name. */
static void bind_profile(struct src *s)
{
	int i;

	remap_reset(&s->map);
	for (i = 0; i < nprofiles; i++) {
		if (fnmatch(profiles[i].match, s->name, FNM_CASEFOLD) == 0) {
			s->map = profiles[i].map;
			logmsg("        profile '%s' applied to %s", profiles[i].match, s->name);
			return;
		}
	}
}

static const struct axis_def *find_axis(int code)
{
	size_t i;
	for (i = 0; i < sizeof(out_axes) / sizeof(out_axes[0]); i++)
		if (out_axes[i].code == code)
			return &out_axes[i];
	return NULL;
}

static int rescale(int v, const struct input_absinfo *s, const struct axis_def *d)
{
	long long num;
	if (s->maximum <= s->minimum)
		return v; /* source never reported a range; pass through */
	if (s->minimum == d->min && s->maximum == d->max)
		return v;
	if (v < s->minimum)
		v = s->minimum;
	if (v > s->maximum)
		v = s->maximum;
	num = (long long)(v - s->minimum) * ((long long)d->max - d->min);
	return d->min + (int)(num / (s->maximum - s->minimum));
}

static void emit(int type, int code, int value)
{
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = value;
	if (write(out_fd, &ev, sizeof(ev)) != sizeof(ev))
		logmsg("warn: write to uinput: %s", strerror(errno));
}

/*
 * Plays or stops the rumble effect on every merged pad that has a motor.
 * There is exactly one game-facing rumble request at a time — the merged pad
 * carries one effect — so every FF-capable source gets the same instruction;
 * a pad with no motor is simply skipped, cand.ff_id having stayed -1.
 */
static void relay_ff(int playing)
{
	struct input_event ev;
	int i;

	memset(&ev, 0, sizeof(ev));
	ev.type = EV_FF;
	ev.value = playing ? 1 : 0;
	for (i = 0; i < nsrc; i++) {
		if (srcs[i].ff_id < 0)
			continue;
		ev.code = srcs[i].ff_id;
		if (write(srcs[i].fd, &ev, sizeof(ev)) != sizeof(ev))
			logmsg("warn: rumble write to %s: %s", srcs[i].name, strerror(errno));
	}
}

/*
 * Handles one event read from our own output device's /dev/uinput fd — not
 * the ordinary input direction, but the one uinput uses for force-feedback:
 * a game uploading or erasing an effect on the merged pad, or playing or
 * stopping one it already uploaded. Accepted unconditionally either way —
 * there is only the one effect this whole pipeline knows how to play, so
 * there is nothing to negotiate.
 */
static void handle_ff_event(const struct input_event *ev)
{
	struct uinput_ff_upload up;
	struct uinput_ff_erase er;

	if (ev->type == EV_UINPUT && ev->code == UI_FF_UPLOAD) {
		memset(&up, 0, sizeof(up));
		up.request_id = ev->value;
		if (ioctl(out_fd, UI_BEGIN_FF_UPLOAD, &up) < 0)
			return;
		up.retval = 0;
		ioctl(out_fd, UI_END_FF_UPLOAD, &up);
	} else if (ev->type == EV_UINPUT && ev->code == UI_FF_ERASE) {
		memset(&er, 0, sizeof(er));
		er.request_id = ev->value;
		if (ioctl(out_fd, UI_BEGIN_FF_ERASE, &er) < 0)
			return;
		er.retval = 0;
		ioctl(out_fd, UI_END_FF_ERASE, &er);
	} else if (ev->type == EV_FF) {
		relay_ff(ev->value != 0);
	}
}

static int looks_like_gamepad(int fd)
{
	unsigned long evbit[NBITS(EV_CNT)], keybit[NBITS(KEY_CNT)], absbit[NBITS(ABS_CNT)];

	memset(evbit, 0, sizeof(evbit));
	memset(keybit, 0, sizeof(keybit));
	memset(absbit, 0, sizeof(absbit));

	if (ioctl(fd, EVIOCGBIT(0, sizeof(evbit)), evbit) < 0)
		return 0;
	if (!test_bit(EV_KEY, evbit))
		return 0;
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybit)), keybit) < 0)
		return 0;
	if (!test_bit(BTN_A, keybit) && !test_bit(BTN_TRIGGER, keybit))
		return 0;
	if (test_bit(EV_ABS, evbit) &&
	    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbit)), absbit) >= 0 &&
	    (test_bit(ABS_X, absbit) || test_bit(ABS_HAT0X, absbit)))
		return 1;
	return test_bit(BTN_DPAD_UP, keybit);
}

static void release_source_keys(struct src *s)
{
	int code, synced = 0;

	for (code = 0; code < KEY_CNT; code++) {
		if (!test_bit(code, s->keystate))
			continue;
		if (key_held[code] > 0 && --key_held[code] == 0) {
			/* Anything held back or withheld was never sent, so there
			 * is nothing to release and no tap to make of it. */
			if (defer_since[code]) {
				defer_since[code] = 0;
				if (mods_down > 0)
					mods_down--;
				continue;
			}
			if (!emitted[code])
				continue;
			emit(EV_KEY, code, 0);
			emitted[code] = 0;
			synced = 1;
		}
	}
	if (synced && out_fd >= 0)
		emit(EV_SYN, SYN_REPORT, 0);
	memset(s->keystate, 0, sizeof(s->keystate));
}

static void drop_source(int idx)
{
	struct src *s = &srcs[idx];

	release_source_keys(s); /* or its held buttons would stick forever */
	logmsg("gone    %s (%s)", s->path, s->name);
	if (s->fd >= 0)
		close(s->fd);
	srcs[idx] = srcs[nsrc - 1];
	nsrc--;
}

/*
 * The AYN mapper mirrors each physical pad into a 0x2020 virtual pad, so the
 * same controller shows up twice under one name. Reading both would replay every
 * press twice and, worse, mix raw codes with the mapper's remapped ones. Keep
 * the AYN copy: that is the one carrying the user's mapping profile.
 */
static int supersedes(const struct src *candidate, const struct src *existing)
{
	if (strcmp(candidate->name, existing->name) != 0)
		return -1; /* unrelated devices */
	return candidate->vendor == AYN_VENDOR && existing->vendor != AYN_VENDOR;
}

/*
 * Uploads the one rumble effect this pad will ever need, if it has a motor to
 * play it on. On/off is all any of the merged pads' protocols support — none
 * of them carry a waveform — so there is nothing to gain from uploading more
 * than one effect or from re-uploading per play.
 */
static int upload_rumble(int fd)
{
	unsigned long ffbit[NBITS(FF_CNT)];
	struct ff_effect effect;

	memset(ffbit, 0, sizeof(ffbit));
	if (ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ffbit)), ffbit) < 0)
		return -1;
	if (!test_bit(FF_RUMBLE, ffbit))
		return -1;

	memset(&effect, 0, sizeof(effect));
	effect.type = FF_RUMBLE;
	effect.id = -1; /* -1 asks the kernel to allocate one */
	effect.u.rumble.strong_magnitude = 0xffff;
	effect.u.rumble.weak_magnitude = 0xffff;
	if (ioctl(fd, EVIOCSFF, &effect) < 0)
		return -1;
	return effect.id;
}

static int add_source(const char *path)
{
	struct src cand;
	struct stat st;
	struct input_id id;
	int fd, code, i;

	if (nsrc >= MAX_SRC)
		return -1;

	/* Read-write so a rumble effect can be uploaded and played on whichever
	 * pads have a motor; falls back to read-only for whichever do not allow
	 * that, so a pad that would otherwise merge fine is not turned away
	 * over a feature it was never going to use. */
	fd = open(path, O_RDWR | O_NONBLOCK);
	if (fd < 0)
		fd = open(path, O_RDONLY | O_NONBLOCK);
	if (fd < 0)
		return -1;

	memset(&cand, 0, sizeof(cand));
	cand.ff_id = -1;
	if (fstat(fd, &st) < 0 || !looks_like_gamepad(fd)) {
		close(fd);
		return -1;
	}
	if (ioctl(fd, EVIOCGNAME(sizeof(cand.name)), cand.name) < 0)
		snprintf(cand.name, sizeof(cand.name), "unknown");
	if (ioctl(fd, EVIOCGID, &id) == 0) {
		cand.vendor = id.vendor;
		cand.product = id.product;
	}

	/* Never read our own pad, nor a copy of it, or events would echo forever. */
	if (st.st_rdev == own_rdev || strcmp(cand.name, VDEV_NAME) == 0) {
		close(fd);
		return -1;
	}

	for (i = 0; i < nsrc; i++) {
		if (srcs[i].rdev == st.st_rdev) { /* already merged */
			close(fd);
			return -1;
		}
		switch (supersedes(&cand, &srcs[i])) {
		case 0: /* an equivalent copy is already merged */
			close(fd);
			return -1;
		case 1:
			logmsg("replacing %s with the AYN copy at %s", srcs[i].path, path);
			drop_source(i);
			i--;
			break;
		default:
			break;
		}
	}

	cand.fd = fd;
	cand.rdev = st.st_rdev;
	snprintf(cand.path, sizeof(cand.path), "%s", path);
	for (code = 0; code < ABS_CNT; code++)
		ioctl(fd, EVIOCGABS(code), &cand.abs[code]);
	cand.ff_id = upload_rumble(fd);

	srcs[nsrc] = cand;
	logmsg("merging %s [%04x:%04x] <- %s%s", cand.name, cand.vendor, cand.product, path,
	       cand.ff_id >= 0 ? " (rumble)" : "");
	bind_profile(&srcs[nsrc]);
	nsrc++;
	return 0;
}

/*
 * Run a shortcut's command, detached, without stalling the input loop.
 *
 * We are root, which is the point: the things worth binding to a combo —
 * a panel's backlight, the volume — need it. SIGCHLD is ignored in main() so
 * these never become zombies, and the child closes our descriptors so a slow
 * command cannot sit on the grabbed pads.
 */
static void run_shortcut(const struct shortcut *sc)
{
	pid_t pid = fork();

	if (pid < 0) {
		logmsg("shortcut: fork failed: %s", strerror(errno));
		return;
	}
	if (pid == 0) {
		for (int fd = 3; fd < 256; fd++)
			close(fd);
		setsid();
		execl("/system/bin/sh", "sh", "-c", sc->cmd, (char *)NULL);
		_exit(127);
	}
}

static long long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Sends an axis where the buttons currently pushing it say it should be. */
static void push_axis(int code, int dir, int pressed)
{
	const struct axis_def *ax = find_axis(code);
	int slot = dir > 0 ? 1 : 0;
	int value;

	if (!ax)
		return;
	if (pressed)
		axis_push[code][slot]++;
	else if (axis_push[code][slot] > 0)
		axis_push[code][slot]--;

	if (axis_push[code][0] && !axis_push[code][1])
		value = ax->min;
	else if (axis_push[code][1] && !axis_push[code][0])
		value = ax->max;
	else
		value = (ax->min + ax->max) / 2;

	emit(EV_ABS, code, value);
	emit(EV_SYN, SYN_REPORT, 0);
}

/* True for a button some combo starts with — the one held while reaching. */
static int is_modifier(int code)
{
	for (int i = 0; i < nshortcuts; i++) {
		if (shortcuts[i].ncodes > 0 && shortcuts[i].codes[0] == code)
			return 1;
	}
	return 0;
}

/* Marks every held modifier as having done its other job. */
static void spend_modifiers(void)
{
	for (int i = 0; i < nshortcuts; i++) {
		int mod = shortcuts[i].codes[0];

		if (shortcuts[i].ncodes > 0 && defer_since[mod])
			defer_spent[mod] = 1;
	}
}

/* Ends a tap's pulse once its 50 ms are up. */
static void flush_taps(void)
{
	long long now = now_ms();
	int synced = 0;

	if (!taps_pending)
		return;
	for (int code = 0; code < KEY_CNT; code++) {
		if (!tap_until[code] || now < tap_until[code])
			continue;
		tap_until[code] = 0;
		taps_pending--;
		emit(EV_KEY, code, 0);
		emitted[code] = 0;
		synced = 1;
	}
	if (synced)
		emit(EV_SYN, SYN_REPORT, 0);
}

/* How long poll() may sleep before a pulse is due. */
static int taps_timeout(int fallback)
{
	long long now = now_ms();
	int wait = fallback;

	if (!taps_pending)
		return fallback;
	for (int code = 0; code < KEY_CNT; code++) {
		if (!tap_until[code])
			continue;
		long long left = tap_until[code] - now;
		if (left < 0)
			left = 0;
		if (left < wait)
			wait = (int)left;
	}
	return wait;
}

/* Sends a held-back press as a pulse the game can see. */
static void tap(int code)
{
	emit(EV_KEY, code, 1);
	emit(EV_SYN, SYN_REPORT, 0);
	emitted[code] = 1;
	if (!tap_until[code])
		taps_pending++;
	tap_until[code] = now_ms() + TAP_PULSE_MS;
}

/*
 * Fires once when every button of a combo is held, and rearms when one is let
 * go, so holding it does not repeat the command.
 *
 * The combo's own buttons are taken back on the way out: the modifier was
 * never sent, and the rest are released so the game does not see them stuck
 * down for as long as the command runs. What the game already received of the
 * later buttons cannot be recalled — a merged pad emits a press as it happens,
 * and a combo is only recognisable once its last button lands.
 */
static void check_shortcuts(void)
{
	for (int i = 0; i < nshortcuts; i++) {
		struct shortcut *sc = &shortcuts[i];
		int all = 1, synced = 0;

		for (int j = 0; j < sc->ncodes; j++) {
			if (!key_held[sc->codes[j]])
				all = 0;
		}
		if (!all) {
			sc->fired = 0;
			continue;
		}
		if (sc->fired)
			continue;

		sc->fired = 1;
		for (int j = 0; j < sc->ncodes; j++) {
			int code = sc->codes[j];
			/* Spent: whatever happens next, this hold was a combo. */
			defer_spent[code] = 1;
			/* Usually nothing to take back — the modifier was held
			 * back and the rest was withheld with it. A button
			 * pressed *before* the modifier did go out, though. */
			if (!emitted[code])
				continue;
			emit(EV_KEY, code, 0);
			emitted[code] = 0;
			synced = 1;
		}
		if (synced)
			emit(EV_SYN, SYN_REPORT, 0);
		logmsg("shortcut: %s", sc->cmd);
		run_shortcut(sc);
	}
}

/* Same held/count bookkeeping release_source_keys() already does for a real
 * button, minus ever emitting anything — a stick pseudo button never reaches
 * the game, [shortcuts] is the only thing that reads it. Returns whether it
 * actually changed, so the caller only re-checks combos on a real edge. */
static int set_pseudo(struct src *s, int code, int pressed)
{
	if (!!pressed == !!test_bit(code, s->keystate))
		return 0;
	if (pressed) {
		s->keystate[code / BITS_PER_LONG] |= 1UL << (code % BITS_PER_LONG);
		key_held[code]++;
	} else {
		s->keystate[code / BITS_PER_LONG] &= ~(1UL << (code % BITS_PER_LONG));
		if (key_held[code] > 0)
			key_held[code]--;
	}
	return 1;
}

/*
 * Feeds [shortcuts] from a stick, on top of [dst]/[v] reaching the game as
 * normal — pushing the right stick down both moves the stick in the game
 * and, if a combo is bound to RSTICK_DOWN, fires it. [v] already has this
 * source's invert and dead zone applied, so a shortcut agrees with whichever
 * direction the game itself sees.
 */
static void update_stick_shortcuts(struct src *s, int dst, int v, const struct axis_def *ax)
{
	int neg_code, pos_code, centre, half, towards_neg, towards_pos, changed = 0;

	switch (dst) {
	case ABS_X:  neg_code = PB_LSTICK_LEFT; pos_code = PB_LSTICK_RIGHT; break;
	case ABS_Y:  neg_code = PB_LSTICK_UP;   pos_code = PB_LSTICK_DOWN;  break;
	case ABS_Z:  neg_code = PB_RSTICK_LEFT; pos_code = PB_RSTICK_RIGHT; break;
	case ABS_RZ: neg_code = PB_RSTICK_UP;   pos_code = PB_RSTICK_DOWN;  break;
	default: return; /* triggers and the d-pad hat make poor shortcut sticks */
	}
	if (!nshortcuts)
		return;

	centre = (ax->min + ax->max) / 2;
	half = ax->max - centre;
	if (half <= 0)
		return;
	towards_neg = (centre - v) * 100 / half;
	towards_pos = (v - centre) * 100 / half;

	if (towards_neg >= STICK_ON)
		changed |= set_pseudo(s, neg_code, 1);
	else if (towards_neg <= STICK_OFF)
		changed |= set_pseudo(s, neg_code, 0);

	if (towards_pos >= STICK_ON)
		changed |= set_pseudo(s, pos_code, 1);
	else if (towards_pos <= STICK_OFF)
		changed |= set_pseudo(s, pos_code, 0);

	if (changed)
		check_shortcuts();
}

/*
 * Line-oriented output for the configuration app, which runs us through su and
 * parses stdout. Tab separated so device names with spaces stay in one field.
 *   EV <device> KEY <BTN_SOUTH> <0|1>
 *   EV <device> ABS <ABS_X> <value>
 */
static void print_watch_event(const struct src *s, const struct input_event *ev)
{
	const char *sym;
	char buf[32];

	if (ev->type == EV_KEY) {
		sym = lookup_name(key_names, ev->code);
		if (!sym) {
			snprintf(buf, sizeof(buf), "%u", ev->code);
			sym = buf;
		}
		printf("EV\t%s\tKEY\t%s\t%d\n", s->name, sym, ev->value ? 1 : 0);
	} else if (ev->type == EV_ABS) {
		sym = lookup_name(abs_names, ev->code);
		if (!sym)
			return; /* an axis we never forward anyway */
		printf("EV\t%s\tABS\t%s\t%d\n", s->name, sym, ev->value);
	} else {
		return;
	}
	fflush(stdout);

	/* The app kills the su process that owns our stdout; without this we would
	 * be reparented to init and linger forever, reading pads for nobody. */
	if (ferror(stdout)) {
		logmsg("stdout closed, exiting watch mode");
		running = 0;
	}
}

static void handle_event(struct src *s, const struct input_event *ev)
{
	const struct axis_def *ax;
	int dst, v;

	switch (ev->type) {
	case EV_KEY:
		if (ev->code >= KEY_CNT || ev->value == 2 /* autorepeat */)
			return;
		/* Ignore a repeat of the state this pad is already in, so the
		 * cross-pad press count cannot drift out of sync. */
		if (!!ev->value == !!test_bit(ev->code, s->keystate))
			return;
		dst = s->map.key[ev->code];
		/* Track state on the source code but count holds on the mapped
		 * one, so a remap stays consistent between press and release. */
		/* A button standing in for a stick never reaches the key path:
		 * combos, taps and the merged key state are all about buttons. */
		if (s->map.key_axis[ev->code] >= 0) {
			if (!!ev->value == !!test_bit(ev->code, s->keystate))
				return;
			if (ev->value)
				s->keystate[ev->code / BITS_PER_LONG] |=
					1UL << (ev->code % BITS_PER_LONG);
			else
				s->keystate[ev->code / BITS_PER_LONG] &=
					~(1UL << (ev->code % BITS_PER_LONG));
			push_axis(s->map.key_axis[ev->code], s->map.key_dir[ev->code],
				  ev->value);
			return;
		}

		if (ev->value) {
			s->keystate[ev->code / BITS_PER_LONG] |= 1UL << (ev->code % BITS_PER_LONG);
			if (dst >= 0 && ++key_held[dst] == 1) {
				/* Pressed again mid-pulse: close the old one first. */
				if (tap_until[dst]) {
					tap_until[dst] = 0;
					taps_pending--;
					emit(EV_KEY, dst, 0);
					emitted[dst] = 0;
				}
				if (is_modifier(dst)) {
					defer_since[dst] = now_ms();
					defer_spent[dst] = 0;
					mods_down++;
				} else if (mods_down > 0) {
					/* On the second layer: withheld whether or not it
					 * completes a combo, and it settles what the
					 * modifier was for. */
					spend_modifiers();
				} else {
					emit(EV_KEY, dst, 1);
					emitted[dst] = 1;
				}
			}
		} else {
			s->keystate[ev->code / BITS_PER_LONG] &= ~(1UL << (ev->code % BITS_PER_LONG));
			if (dst >= 0 && key_held[dst] > 0 && --key_held[dst] == 0) {
				if (defer_since[dst]) {
					long long held = now_ms() - defer_since[dst];

					defer_since[dst] = 0;
					if (mods_down > 0)
						mods_down--;
					/* Quick and on its own: the player meant the button. */
					if (!defer_spent[dst] && held < TAP_MAX_MS)
						tap(dst);
				} else if (emitted[dst]) {
					emit(EV_KEY, dst, 0);
					emitted[dst] = 0;
				}
			}
		}
		/* On release too, so letting a button go rearms the combo. */
		if (nshortcuts)
			check_shortcuts();
		break;
	case EV_ABS:
		if (ev->code >= ABS_CNT)
			return;
		dst = s->map.axis[ev->code];
		if (dst < 0)
			return;
		ax = find_axis(dst);
		if (!ax)
			return;
		v = rescale(ev->value, &s->abs[ev->code], ax);
		if (s->map.invert[ev->code])
			v = ax->min + ax->max - v;
		if (s->map.deadzone[ev->code] > 0) {
			int centre = (ax->min + ax->max) / 2;
			if (v - centre < s->map.deadzone[ev->code] &&
			    centre - v < s->map.deadzone[ev->code])
				v = centre;
		}
		emit(EV_ABS, dst, v);
		update_stick_shortcuts(s, dst, v, ax);
		break;
	case EV_SYN:
		if (ev->code == SYN_REPORT)
			emit(EV_SYN, SYN_REPORT, 0);
		break;
	default:
		break;
	}
}

static int create_virtual(void)
{
	struct uinput_setup us;
	struct uinput_abs_setup as;
	size_t i;
	int fd;

	/* Read-write, not write-only: force-feedback upload/erase requests and
	 * play events arrive as reads on this same fd, the one that created the
	 * device — uinput has no separate channel for them. */
	fd = open("/dev/uinput", O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		logmsg("error: open /dev/uinput: %s", strerror(errno));
		return -1;
	}

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	ioctl(fd, UI_SET_EVBIT, EV_FF);
	ioctl(fd, UI_SET_FFBIT, FF_RUMBLE);

	for (i = 0; i < sizeof(out_keys) / sizeof(out_keys[0]); i++)
		ioctl(fd, UI_SET_KEYBIT, out_keys[i]);

	for (i = 0; i < sizeof(out_axes) / sizeof(out_axes[0]); i++) {
		ioctl(fd, UI_SET_ABSBIT, out_axes[i].code);
		memset(&as, 0, sizeof(as));
		as.code = out_axes[i].code;
		as.absinfo.minimum = out_axes[i].min;
		as.absinfo.maximum = out_axes[i].max;
		as.absinfo.fuzz = out_axes[i].fuzz;
		as.absinfo.flat = out_axes[i].flat;
		if (ioctl(fd, UI_ABS_SETUP, &as) < 0)
			logmsg("warn: UI_ABS_SETUP %d: %s", out_axes[i].code, strerror(errno));
	}

	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_USB;
	us.id.vendor = VDEV_VENDOR;
	us.id.product = VDEV_PRODUCT;
	us.id.version = VDEV_VERSION;
	snprintf(us.name, sizeof(us.name), VDEV_NAME);
	us.ff_effects_max = 1; /* on/off is all any merged pad's rumble carries */

	if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		logmsg("error: creating uinput device: %s", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

/*
 * Find our own /dev/input node and lock it to 0660 root:input. This is what
 * keeps com.odin.mapping (uid system, but not in group input) from cloning us
 * into a second pad, while system_server (in group input) still sees it.
 */
static void claim_own_node(void)
{
	char sysname[64] = { 0 };
	char dir[128];
	struct dirent *de;
	struct stat st;
	DIR *d;
	int i;

	if (ioctl(out_fd, UI_GET_SYSNAME(sizeof(sysname)), sysname) < 0) {
		logmsg("warn: UI_GET_SYSNAME: %s", strerror(errno));
		return;
	}
	snprintf(dir, sizeof(dir), "/sys/class/input/%s", sysname);
	d = opendir(dir);
	if (!d) {
		logmsg("warn: opendir %s: %s", dir, strerror(errno));
		return;
	}
	while ((de = readdir(d))) {
		if (strncmp(de->d_name, "event", 5) != 0)
			continue;
		snprintf(own_path, sizeof(own_path), "/dev/input/%s", de->d_name);
		break;
	}
	closedir(d);

	if (!own_path[0]) {
		logmsg("warn: could not locate our own node under %s", dir);
		return;
	}

	/* The sysfs entry exists as soon as UI_DEV_CREATE returns, but ueventd
	 * creates the /dev node a moment later. Wait for it, or we would lock
	 * down nothing and stay clonable. */
	for (i = 0; i < 100; i++) {
		if (stat(own_path, &st) == 0)
			break;
		usleep(20 * 1000);
	}
	if (i == 100) {
		logmsg("warn: %s never appeared; cannot lock it down", own_path);
		return;
	}
	own_rdev = st.st_rdev;

	if (chown(own_path, 0, AID_INPUT) != 0 || chmod(own_path, 0660) != 0)
		logmsg("warn: cannot lock down %s: %s", own_path, strerror(errno));
	else
		logmsg("our pad is %s, locked to 0660 root:input", own_path);
}

static void scan_all(void)
{
	struct dirent *de;
	char path[64];
	DIR *d = opendir("/dev/input");

	if (!d) {
		logmsg("error: opendir /dev/input: %s", strerror(errno));
		return;
	}
	while ((de = readdir(d))) {
		if (strncmp(de->d_name, "event", 5) == 0) {
			snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
			add_source(path);
		}
	}
	closedir(d);
}

int main(int argc, char **argv)
{
	struct pollfd pfd[MAX_SRC + 2];
	struct input_event evs[64];
	char inbuf[4096];
	int inotify_fd, i, n, rc, nfds;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v")) {
			opt_verbose = 1;
		} else if (!strcmp(argv[i], "-c") && i + 1 < argc) {
			cfg_path = argv[++i];
		} else if (!strcmp(argv[i], "--list")) {
			opt_list = 1;
		} else if (!strcmp(argv[i], "--watch")) {
			opt_watch = 1;
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			printf("usage: %s [-v] [-c CONFIG] [--list] [--watch]\n\n"
			       "Merges every gamepad into one virtual pad named '%s'.\n"
			       "Source pads must be listed in excluded-input-devices.xml\n"
			       "so Android ignores them. Nothing is grabbed or unlinked.\n\n"
			       "  -v          log every incoming event\n"
			       "  -c CONFIG   profile file (default %s)\n"
			       "  --list      print the merged pads and exit, as\n"
			       "              DEV<tab>name<tab>vendor<tab>product<tab>node\n"
			       "  --watch     stream events as EV<tab>pad<tab>KEY|ABS<tab>code<tab>value\n"
			       "              (creates no device; safe while the daemon runs)\n\n"
			       "Send SIGHUP to reload profiles without disconnecting pads:\n"
			       "  pkill -HUP gpmerge\n",
			       argv[0], VDEV_NAME, CONFIG_PATH);
			return 0;
		} else {
			/* Never fall through to daemon mode on a typo or on an
			 * option an older binary does not know: that would create
			 * a second virtual pad behind the running daemon. */
			logmsg("error: unknown option '%s' (try --help)", argv[i]);
			return 2;
		}
	}

	if (geteuid() != 0) {
		logmsg("error: must run as root");
		return 1;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGHUP, on_signal); /* reload profiles */
	signal(SIGPIPE, SIG_IGN);
	/* Shortcut commands are fire and forget; never wait on one, never keep
	 * its corpse. */
	signal(SIGCHLD, SIG_IGN);

	load_config();

	/* --list and --watch inspect the existing pads; they must not create a
	 * second virtual controller alongside the running daemon. */
	if (!opt_list && !opt_watch) {
		out_fd = create_virtual();
		if (out_fd < 0)
			return 1;
		claim_own_node();
	}

	inotify_fd = inotify_init1(IN_NONBLOCK);
	if (inotify_fd >= 0)
		inotify_add_watch(inotify_fd, "/dev/input", IN_CREATE);
	else
		logmsg("warn: inotify unavailable, hotplug disabled");

	scan_all();

	if (opt_list) {
		for (i = 0; i < nsrc; i++)
			printf("DEV\t%s\t%04x\t%04x\t%s\n", srcs[i].name,
			       srcs[i].vendor, srcs[i].product, srcs[i].path);
		return 0;
	}

	if (opt_watch) {
		/* Announce each axis and its range up front. The configuration app
		 * needs it to tell a stick from a d-pad hat: raw travel alone is
		 * meaningless without knowing the scale it is measured on. */
		int a;
		for (i = 0; i < nsrc; i++) {
			for (a = 0; a < ABS_CNT; a++) {
				const char *sym = lookup_name(abs_names, a);
				if (!sym || srcs[i].abs[a].maximum <= srcs[i].abs[a].minimum)
					continue;
				printf("AXIS\t%s\t%s\t%d\t%d\n", srcs[i].name, sym,
				       srcs[i].abs[a].minimum, srcs[i].abs[a].maximum);
			}
		}
		fflush(stdout);
	} else {
		logmsg("merging %d gamepad(s) into '%s'", nsrc, VDEV_NAME);
	}

	while (running) {
		int ff_slot = -1;

		for (i = 0; i < nsrc; i++) {
			pfd[i].fd = srcs[i].fd;
			pfd[i].events = POLLIN;
			pfd[i].revents = 0;
		}
		pfd[nsrc].fd = inotify_fd;
		pfd[nsrc].events = POLLIN;
		pfd[nsrc].revents = 0;
		nfds = nsrc + 1;

		if (reload_cfg) {
			reload_cfg = 0;
			/* Release everything first: a button pressed under the old
			 * mapping would otherwise never receive its release. */
			for (i = 0; i < nsrc; i++)
				release_source_keys(&srcs[i]);
			load_config();
			for (i = 0; i < nsrc; i++)
				bind_profile(&srcs[i]);
		}

		/* Our own output fd, not one of nsrc's: force-feedback requests from
		 * a game arrive here, not on any source. Not opened in --list or
		 * --watch mode, so there is nothing to poll there. */
		if (out_fd >= 0) {
			ff_slot = nfds;
			pfd[ff_slot].fd = out_fd;
			pfd[ff_slot].events = POLLIN;
			pfd[ff_slot].revents = 0;
			nfds++;
		}

		/* In watch mode also notice our reader going away even while no
		 * button is pressed, so we never linger orphaned under init. */
		if (opt_watch) {
			pfd[nfds].fd = STDOUT_FILENO;
			pfd[nfds].events = 0;
			pfd[nfds].revents = 0;
			nfds++;
		}

		/* Sleep no longer than a pending tap's pulse has left to run. */
		rc = poll(pfd, nfds, taps_timeout(1000));
		if (rc < 0) {
			if (errno == EINTR)
				continue;
			logmsg("error: poll: %s", strerror(errno));
			break;
		}
		flush_taps();

		if (opt_watch &&
		    (pfd[nfds - 1].revents & (POLLERR | POLLHUP | POLLNVAL))) {
			logmsg("stdout closed, exiting watch mode");
			break;
		}

		for (i = nsrc - 1; i >= 0; i--) {
			if (!pfd[i].revents)
				continue;
			if (pfd[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
				drop_source(i); /* pad disconnected */
				continue;
			}
			n = read(srcs[i].fd, evs, sizeof(evs));
			if (n <= 0) {
				if (n == 0 || (errno != EAGAIN && errno != EINTR))
					drop_source(i);
				continue;
			}
			for (rc = 0; rc < n / (int)sizeof(struct input_event); rc++) {
				if (opt_verbose)
					logmsg("  %s type=%u code=%u val=%d", srcs[i].name,
					       evs[rc].type, evs[rc].code, evs[rc].value);
				if (opt_watch)
					print_watch_event(&srcs[i], &evs[rc]);
				else
					handle_event(&srcs[i], &evs[rc]);
			}
		}

		if (pfd[nsrc].revents & POLLIN) {
			n = read(inotify_fd, inbuf, sizeof(inbuf));
			for (rc = 0; rc + (int)sizeof(struct inotify_event) <= n;) {
				struct inotify_event *ie = (struct inotify_event *)&inbuf[rc];
				if (ie->len && strncmp(ie->name, "event", 5) == 0) {
					char path[64];
					snprintf(path, sizeof(path), "/dev/input/%s", ie->name);
					usleep(200 * 1000); /* let ueventd set ownership */
					add_source(path);
				}
				rc += sizeof(struct inotify_event) + ie->len;
			}
		}

		if (ff_slot >= 0 && pfd[ff_slot].revents & POLLIN) {
			n = read(out_fd, evs, sizeof(evs));
			if (n > 0)
				for (rc = 0; rc < n / (int)sizeof(struct input_event); rc++)
					handle_ff_event(&evs[rc]);
		}
	}

	logmsg("shutting down");
	for (i = 0; i < nsrc; i++) {
		release_source_keys(&srcs[i]);
		close(srcs[i].fd);
	}
	ioctl(out_fd, UI_DEV_DESTROY);
	close(out_fd);
	return 0;
}
