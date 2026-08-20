/*
 * gpmtest - inject KEY_HOME from a synthetic uinput device, to find out whether
 * Android honours it depending on how the device presents itself.
 *
 *   gpmtest keyboard   device exposing KEY_HOME only
 *   gpmtest gamepad    same ids and capabilities as the merged pad
 *
 * If Home works in one shape and not the other, the problem is the device class
 * rather than anything in the event chain.
 */

#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>

static void emit(int fd, int type, int code, int val)
{
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = val;
	write(fd, &ev, sizeof(ev));
}

int main(int argc, char **argv)
{
	struct uinput_setup us;
	struct uinput_abs_setup as;
	int gamepad = (argc > 1 && strcmp(argv[1], "gamepad") == 0);
	int fd, i;
	static const int keys[] = {
		BTN_A, BTN_B, BTN_X, BTN_Y, BTN_TL, BTN_TR,
		BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR,
	};
	static const int axes[] = { ABS_X, ABS_Y, ABS_Z, ABS_RZ };

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) {
		perror("open /dev/uinput");
		return 1;
	}

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_KEYBIT, KEY_HOME);

	if (gamepad) {
		ioctl(fd, UI_SET_EVBIT, EV_ABS);
		for (i = 0; i < (int)(sizeof(keys) / sizeof(keys[0])); i++)
			ioctl(fd, UI_SET_KEYBIT, keys[i]);
		for (i = 0; i < (int)(sizeof(axes) / sizeof(axes[0])); i++) {
			ioctl(fd, UI_SET_ABSBIT, axes[i]);
			memset(&as, 0, sizeof(as));
			as.code = axes[i];
			as.absinfo.minimum = -32768;
			as.absinfo.maximum = 32767;
			ioctl(fd, UI_ABS_SETUP, &as);
		}
	}

	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_USB;
	us.id.vendor = 0x2020;
	us.id.product = 0x0111;
	us.id.version = 0x0100;
	snprintf(us.name, sizeof(us.name), "GPM Home Test %s",
		 gamepad ? "Gamepad" : "Keyboard");

	if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		perror("create uinput device");
		return 1;
	}
	printf("created '%s', waiting for Android to enumerate it\n", us.name);
	sleep(3);

	printf("sending KEY_HOME\n");
	emit(fd, EV_KEY, KEY_HOME, 1);
	emit(fd, EV_SYN, SYN_REPORT, 0);
	usleep(60 * 1000);
	emit(fd, EV_KEY, KEY_HOME, 0);
	emit(fd, EV_SYN, SYN_REPORT, 0);

	sleep(2);
	ioctl(fd, UI_DEV_DESTROY);
	close(fd);
	printf("done\n");
	return 0;
}
