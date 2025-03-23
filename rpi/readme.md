# Sources

The following files were originally from other projects.  Some of these files are verbatim copies, some of them have been locally modified.

- moonraker.conf -> https://github.com/Guilouz/Creality-Helper-Script/blob/main/files/moonraker/moonraker.conf
- sensorless.cfg -> https://raw.githubusercontent.com/K1-Klipper/installer_script_k1_and_max/main/sensorless.cfg
- cartographer_macro.cfg -> https://raw.githubusercontent.com/K1-Klipper/cartographer-klipper/master/cartographer_macro.cfg
- guppyscreen.cfg -> https://github.com/ballaswag/guppyscreen/blob/main/k1/scripts/guppy_cmd.cfg
- gcode_shell_command.py -> https://github.com/dw-0/kiauh/blob/master/resources/gcode_shell_command.py
- btteddy.cfg, btteddy_macro.cfg originally from -> https://github.com/ballaswag/creality_k1_klipper_mod/tree/master/printer_configs
- Smart_Park.cfg, Line_Purge.cfg originally from https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging

## Kiuah

I have taken advantage of the fact kiauh is open source to copy and modify as appropriate some config files from this project,
specifically some service files and some nginx config.

## Helper Script

I have taken advantage of the fact helper script is open source to migrate some features from helper script to this project including:

- Some useful macros for fan control
- WARMUP macro

## Klipper

We are using my fork of klipper, which is mainline klipper, a fix for a temp sensor on the k1 and and a time out fix for bltouch,
crtouch and microprobe to the mcu.py file.
