# ExAtomVM

ExAtomVM provide a collection of [Mix](https://hexdocs.pm/mix/Mix.html) tasks that  greatly simplify development and deployment of Elixir applications targeted for the AtomVM platform.

The following operations are supported:

* Packing compiled BEAM files into AVM files for use in AtomVM;
* Flashing AVM files to micro-controllers (Currently ESP32, STM32 and PICO/PICO2 devices are supported by this plugin).

## Dependencies

To use this plugin to build packbeam files, you will need

* [Erlang/OTP](https://erlang.org) 21-27
* [Elixir](https://elixir-lang.org) 1.13 (or higher)

To flash an ExAtomVM project to an ESP32, you will need:

* An ESP32 development module such as the Espressif DevKit C
* A USB cable to connect the ESP32 development module to your workstation
* [esptool](https://github.com/espressif/esptool)
* (Optional) A serial console program, such as `minicom`

Consult your local package manager for installation of these tools.

## Getting Started

Start by creating a Mix project

    shell$ mix new my_project --module MyProject
    * creating README.md
    * creating .formatter.exs
    * creating .gitignore
    * creating mix.exs
    * creating lib
    * creating lib/my_project.ex
    * creating test
    * creating test/test_helper.exs
    * creating test/my_project_test.exs

    Your Mix project was created successfully.
    You can use "mix" to compile it, test it, and more:

        cd my_project
        mix test

    Run "mix help" for more commands.

Edit the generated `mix.exs` to include the ExAtomVM dependency (`{:exatomvm, git: "https://github.com/atomvm/ExAtomVM"}`), and add a properties list using the `atomvm` key containing a `start` and a `flash_offset` (used by ESP32) entry:

    ## elixir
    defmodule MyProject.MixProject do
    use Mix.Project

        def project do
        [
            app: :my_project,
            version: "0.1.0",
            elixir: "~> 1.13",
            start_permanent: Mix.env() == :prod,
            deps: deps(),
            atomvm: [
              start: MyProject,
              flash_offset: 0x250000
            ]
        ]
        end

        # Run "mix help compile.app" to learn about applications.
        def application do
        [
            extra_applications: [:logger]
        ]
        end

        # Run "mix help deps" to learn about dependencies.
        defp deps do
        [
            {:exatomvm, git: "https://github.com/atomvm/ExAtomVM"}
            # {:dep_from_hexpm, "~> 0.3.0"},
            # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
        ]
        end
    end

> Note.  By convention, Mix dependencies are encapsulated in the private `deps` function in the project module (`mix.exs`).

Edit the `my_project.ex` file so that it contains a `start` function:

    ## elixir
    defmodule MyProject do
      def start do
        :ok
      end
    end

Run `mix deps.get` to download ExAtomVM into your `deps` directory:

    shell$ mix deps.get
    * Getting exatomvm (https://github.com/atomvm/ExAtomVM/)
    remote: Enumerating objects: 150, done.
    remote: Counting objects: 100% (29/29), done.
    remote: Compressing objects: 100% (17/17), done.
    remote: Total 150 (delta 14), reused 19 (delta 10), pack-reused 121
    origin/HEAD set to master

Create a directory called `avm_deps` in the top level of your project directory:

    shell$ mkdir avm_deps

Download a copy of the AtomVM-libs from the AtomVM Gitbub [release repository](https://github.com/atomvm/AtomVM/releases/).  Extract the contents of this archive and copy the enclosed AVM files into your `avm_deps` directory.

Afterwards, you should see something like:

    shell$ ls -l avm_deps
    total 264
    -rw-rw-r--  1 frege  wheel  193560 May  8 16:32 atomvmlib.avm

Run the `atomvm.packbeam` Mix task to create a packbeam file:

    shell$ mix atomvm.packbeam
    ==> exatomvm
    Compiling 5 files (.ex)
    Generated exatomvm app
    ==> my_project
    Compiling 1 file (.ex)
    Generated my_project app

The `my_project.avm` file should be created in the top level directory of your project:

    shell$ ls -l my_project.avm
    -rw-rw-r--  1 frege  wheel  144148 May  8 16:34 my_project.avm

You can optionally use the [AtomVM Packbeam](https://github.com/atomvm/atomvm_packbeam) tool to view the contents of this AVM file.

    shell$ packbeam list my_project.avm
    Elixir.MyProject.beam * [500]
    Elixir.Mix.Tasks.Atomvm.Check.beam [5684]
    Elixir.Mix.Tasks.Atomvm.Packbeam.beam [5188]
    Elixir.ExAtomVM.PackBEAM.beam [3412]
    Elixir.ExAtomVM.beam [504]
    Elixir.Mix.Tasks.Atomvm.Esp32.Flash.beam [2048]
    atomvm.beam [412]
    console.beam [840]
    esp.beam [912]
    gpio.beam [1216]
    ...

To flash your project to an ESP32 device, use the `atomvm.esp32.flash` mix task.  You can optionally specify the USB device using the `--port` option:`

    shell% mix atomvm.esp32.flash --port /dev/tty.usbserial
    Generated my_project app
    esptool.py v3.2-dev
    Serial port /dev/tty.usbserial
    Connecting.........
    Chip is ESP32-D0WDQ6-V3 (revision 3)
    Features: WiFi, BT, Dual Core, 240MHz, VRef calibration in efuse, Coding Scheme None
    Crystal is 40MHz
    MAC: 30:c6:f7:2a:54:7c
    Uploading stub...
    Running stub...
    Stub running...
    Configuring flash size...
    Auto-detected Flash size: 4MB
    Flash will be erased from 0x00210000 to 0x00233fff...
    Writing at 0x00210000... (11 %)
    Writing at 0x00214000... (22 %)
    Writing at 0x00218000... (33 %)
    Writing at 0x0021c000... (44 %)
    Writing at 0x00220000... (55 %)
    Writing at 0x00224000... (66 %)
    Writing at 0x00228000... (77 %)
    Writing at 0x0022c000... (88 %)
    Writing at 0x00230000... (100 %)
    Wrote 147456 bytes at 0x00210000 in 13.0 seconds (91.0 kbit/s)...
    Hash of data verified.

    Leaving...
    Hard resetting via RTS pin...


(Optional) To view the console output of your application, use a serial console program, such as `minicom`:

    shell$ minicom -D /dev/tty.usbserial
    rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)
    configsip: 0, SPIWP:0xee
    clk_drv:0x00,q_drv:0x00,d_drv:0x00,cs0_drv:0x00,hd_drv:0x00,wp_drv:0x00
    mode:DIO, clock div:2
    load:0x3fff0018,len:4
    load:0x3fff001c,len:6816
    ho 0 tail 12 room 4
    load:0x40078000,len:12108
    load:0x40080400,len:6664
    entry 0x40080774
    I (76) boot: Chip Revision: 3
    I (77) boot_comm: chip revision: 3, min. bootloader chip revision: 0
    I (42) boot: ESP-IDF v3.3.4-dirty 2nd stage bootloader
    I (42) boot: compile time 14:28:14
    I (42) boot: Enabling RNG early entropy source...
    I (47) boot: SPI Speed      : 40MHz
    I (51) boot: SPI Mode       : DIO
    I (55) boot: SPI Flash Size : 4MB
    I (59) boot: Partition Table:
    I (63) boot: ## Label            Usage          Type ST Offset   Length
    I (70) boot:  0 nvs              WiFi data        01 02 00009000 00006000
    I (77) boot:  1 phy_init         RF data          01 01 0000f000 00001000
    I (85) boot:  2 factory          factory app      00 00 00010000 001c0000
    I (92) boot:  3 lib.avm          RF data          01 01 001d0000 00040000
    I (100) boot:  4 main.avm         RF data          01 01 00210000 00100000
    I (107) boot: End of partition table
    I (112) boot_comm: chip revision: 3, min. application chip revision: 0
    I (119) esp_image: segment 0: paddr=0x00010020 vaddr=0x3f400020 size=0x2cb14 (183060) map
    I (194) esp_image: segment 1: paddr=0x0003cb3c vaddr=0x3ffb0000 size=0x034d4 ( 13524) load
    I (200) esp_image: segment 2: paddr=0x00040018 vaddr=0x400d0018 size=0xd38d8 (866520) map
    I (516) esp_image: segment 3: paddr=0x001138f8 vaddr=0x3ffb34d4 size=0x01524 (  5412) load
    I (518) esp_image: segment 4: paddr=0x00114e24 vaddr=0x40080000 size=0x00400 (  1024) load
    I (523) esp_image: segment 5: paddr=0x0011522c vaddr=0x40080400 size=0x17848 ( 96328) load
    I (573) esp_image: segment 6: paddr=0x0012ca7c vaddr=0x400c0000 size=0x00064 (   100) load
    I (573) esp_image: segment 7: paddr=0x0012cae8 vaddr=0x50000000 size=0x00804 (  2052) load
    I (595) boot: Loaded app from partition at offset 0x10000
    I (595) boot: Disabling RNG early entropy source...
    I (596) cpu_start: Pro cpu up.
    I (599) cpu_start: Application information:
    I (604) cpu_start: Project name:     atomvvm-esp32
    I (610) cpu_start: App version:      e34e0ed-dirty
    I (615) cpu_start: Compile time:     Apr  3 2022 14:28:20
    I (621) cpu_start: ELF file SHA256:  30205fd9063bc42e...
    I (627) cpu_start: ESP-IDF:          v3.3.4-dirty
    I (633) cpu_start: Starting app cpu, entry point is 0x40081410
    I (0) cpu_start: App cpu up.
    I (643) heap_init: Initializing. RAM available for dynamic allocation:
    I (650) heap_init: At 3FFAE6E0 len 00001920 (6 KiB): DRAM
    I (656) heap_init: At 3FFBAC98 len 00025368 (148 KiB): DRAM
    I (662) heap_init: At 3FFE0440 len 00003AE0 (14 KiB): D/IRAM
    I (669) heap_init: At 3FFE4350 len 0001BCB0 (111 KiB): D/IRAM
    I (675) heap_init: At 40097C48 len 000083B8 (32 KiB): IRAM
    I (681) cpu_start: Pro cpu start user code
    I (28) cpu_start: Starting scheduler on PRO CPU.
    I (0) cpu_start: Starting scheduler on APP CPU.

        ###########################################################

           ###    ########  #######  ##     ## ##     ## ##     ##
          ## ##      ##    ##     ## ###   ### ##     ## ###   ###
         ##   ##     ##    ##     ## #### #### ##     ## #### ####
        ##     ##    ##    ##     ## ## ### ## ##     ## ## ### ##
        #########    ##    ##     ## ##     ##  ##   ##  ##     ##
        ##     ##    ##    ##     ## ##     ##   ## ##   ##     ##
        ##     ##    ##     #######  ##     ##    ###    ##     ##

        ###########################################################

    I (130) AtomVM: Starting AtomVM revision 0.5.0
    I (130) AtomVM: Loaded BEAM partition main.avm at address 0x250000 (size=1048576 bytes)
    I (160) atomvm_adc: eFuse Two Point: NOT supported
    I (160) atomvm_adc: eFuse Vref: Supported
    I (160) AtomVM: Found startup beam Elixir.MyProject.beam
    I (160) AtomVM: Loaded BEAM partition lib.avm at address 0x1d0000 (size=262144 bytes)
    I (170) AtomVM: Starting Elixir.MyProject.beam...
    ---
    AtomVM finished with return value: ok
    I (180) AtomVM: AtomVM application terminated.  Going to sleep forever ...

## Reference

### `mix.exs` Configuration

To use this Mix plugin, add `ExAtomVM` to the dependencies list in your `mix.exs` project file.

    def project do [
        ...
        deps: [
          ...
          {:exatomvm, git: "https://github.com/atomvm/ExAtomVM"},
          ...
        ],
        ...
        atomvm: [
            start: HelloWorld,
            flash_offset: 0x250000
        ]
      ]
    end

In addition, you may specify AtomVM-specific configuration using the `atomvm` tag.  The fields in this properties list are described in more detail below.

### The `atomvm.packbeam` task

The `atomvm.packbeam` task is used to bundle your application into an AVM file that can be flashed to a micro-controller and executed by the AtomVM virtual machine.

The `atomvm` properties list in the Mix project file (`mix.exs`) may contain the following entries related to this task:

| Key | Type | Default | Value |
|-----|------|----------|-------|
| `start` | Module | - | The name of the module containing the `start/0` entrypoint function |

Properties in the `mix.exs` file may be over-ridden on the command line using long-style flags (prefixed by `--`) by the same name as the properties key.  For example, you can use the `--start` option to specify or override the `start` property in the above table.

Example:

    shell$ mix atomvm.packbeam --start MyProject
    ==> exatomvm
    Compiling 5 files (.ex)
    Generated exatomvm app
    ==> my_project
    Compiling 1 file (.ex)
    Generated my_project app

### The `atomvm.esp32.flash` task

The `atomvm.esp32.flash` task is used to flash your application to a micro-controller and executed by the AtomVM virtual machine.

> Note.  Before running this task, you must flash the AtomVM virtual machine to the device.  See the [Getting Started](https://www.atomvm.net/doc/master/getting-started-guide.html) section if the [AtomVM documentation](https://www.atomvm.net/doc/master/) for information about how to flash the AtomVM image to a device.

The `atomvm` properties list in the Mix project file (`mix.exs`) may contain the following entries related to this task:

| Key | Type | Default | Value |
|-----|------|----------|-------|
| `flash_offset` | Address in hexademical format | 0x250000 | The name of the module containing the `start/0` entrypoint function |
| `chip` | `esp32` | `esp32` | Chip type |
| `port` | device path | `/dev/ttyUSB0` | Port to which device is connected on host computer |
| `baud` | integer | 115200 | BAUD rate used when flashing to device |

Properties in the `mix.exs` file may be over-ridden on the command line using long-style flags (prefixed by `--`) by the same name as the properties key.  For example, you can use the `--port` option to specify or override the `port` property in the above table.

If the `IDF_PATH` environment variable is set, then the `esptool.py` from the [IDF SDK](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/index.html) installation will be used to flash the application to the ESP32 device.  Otherwise, this plugin will attempt to use the `esptool.py` program from the user's `PATH` environment variable.  The [ESP Tool](https://github.com/espressif/esptool) Python3 application can be installed from source or via many popular package managers.  Consult your local OS documentation for more information.

Example:

    shell$ mix atomvm.esp32.flash --port /dev/tty.usbserial
    Generated my_project app
    esptool.py v3.2-dev
    Serial port /dev/tty.usbserial
    Connecting.........
    Chip is ESP32-D0WDQ6-V3 (revision 3)
    Features: WiFi, BT, Dual Core, 240MHz, VRef calibration in efuse, Coding Scheme None
    Crystal is 40MHz
    MAC: 30:c6:f7:2a:54:7c
    Uploading stub...
    Running stub...
    Stub running...
    Configuring flash size...
    Auto-detected Flash size: 4MB
    Flash will be erased from 0x00210000 to 0x00233fff...
    Writing at 0x00210000... (11 %)
    Writing at 0x00214000... (22 %)
    Writing at 0x00218000... (33 %)
    Writing at 0x0021c000... (44 %)
    Writing at 0x00220000... (55 %)
    Writing at 0x00224000... (66 %)
    Writing at 0x00228000... (77 %)
    Writing at 0x0022c000... (88 %)
    Writing at 0x00230000... (100 %)
    Wrote 147456 bytes at 0x00210000 in 13.0 seconds (91.0 kbit/s)...
    Hash of data verified.

    Leaving...
    Hard resetting via RTS pin...

### The `atomvm.stm32.flash` task

The `atomvm.stm32.flash` task is used to flash your application to a micro-controller and executed by the AtomVM virtual machine.

> Note.  Before running this task, you must flash the AtomVM virtual machine to the device.  See the [Getting Started](https://www.atomvm.net/doc/master/getting-started-guide.html) section if the [AtomVM documentation](https://www.atomvm.net/doc/master/) for information about how to flash the AtomVM image to a device.

The `atomvm` properties list in the Mix project file (`mix.exs`) may contain the following entries related to this task:

| Key | Type | Default | Value |
|-----|------|----------|-------|
| `stflash_path` | string | undefined | The full path to the `st-flash` utility, if not in users PATH |
| `flash_offset` | Address in hexademical format | 0x8080000 | The beginning flash address to write to  |

Properties in the `mix.exs` file may be over-ridden on the command line using long-style flags (prefixed by `--`) by the same name as the properties key.  For example, you can use the `--stflash_path` option to specify or override the `stflash_path` property in the above table.

Example:

    shell$ mix atomvm.stm32.flash
    st-flash 1.7.0
    2023-10-31T10:47:20 INFO common.c: F42x/F43x: 256 KiB SRAM, 2048 KiB flash in at least 16 KiB pages.
    file Blinky.avm md5 checksum: 3dca925a9616d4d65dc9d87fbf19af, stlink checksum: 0x00767ad5
    2023-10-31T10:47:20 INFO common.c: Attempting to write 156172 (0x2620c) bytes to stm32 address: 134742016 (0x8080000)
    EraseFlash - Sector:0x8 Size:0x20000 2023-10-31T10:47:22 INFO common.c: Flash page at addr: 0x08080000 erased
    EraseFlash - Sector:0x9 Size:0x20000 2023-10-31T10:47:24 INFO common.c: Flash page at addr: 0x080a0000 erased
    2023-10-31T10:47:24 INFO common.c: Finished erasing 2 pages of 131072 (0x20000) bytes
    2023-10-31T10:47:24 INFO common.c: Starting Flash write for F2/F4/F7/L4
    2023-10-31T10:47:24 INFO flash_loader.c: Successfully loaded flash loader in sram
    2023-10-31T10:47:24 INFO flash_loader.c: Clear DFSR
    2023-10-31T10:47:24 INFO common.c: enabling 32-bit flash writes
    2023-10-31T10:47:26 INFO common.c: Starting verification of write complete
    2023-10-31T10:47:27 INFO common.c: Flash written and verified! jolly good!

### The `atomvm.pico.flash` task

The `atomvm.pico.flash` task is used to flash your application to a micro-controller and executed by the AtomVM virtual machine.

> Note.  Before running this task, you must flash the AtomVM virtual machine to the device.  See the [Getting Started](https://www.atomvm.net/doc/master/getting-started-guide.html) section if the [AtomVM documentation](https://www.atomvm.net/doc/master/) for information about how to flash the AtomVM image to a device.

The `atomvm` properties list in the Mix project file (`mix.exs`) may contain the following entries related to this task:

| Key | Type | Default | Value |
|-----|------|----------|-------|
| `pico_path` | string | "/run/media/${USER}/RPI-RP2" on linux; "/Volumes/RPI-RP2" on darwin (Mac) | The full path to the pico mount point |
| `pico_reset` | string |"/dev/ttyACM*"  on linux; "/dev/cu.usbmodem14*" on darwin | The full path to the pico device to reset if required |
| `picotool` | string | undefined | The full path to picotool executable (currently optional) |

Properties in the `mix.exs` file may be over-ridden on the command line using long-style flags (prefixed by `--`) by the same name as the properties key.  For example, you can use the `--pico_path` option to specify or override the `pico_path` property in the above table.

### The `atomvm.uf2create` task

The `atomvm.uf2create` is use to create uf2 files appropriate for pico devices from a packed .avm application file, if the packed file does not exist the `atomvm.packbeam` task will be used to create the file (after compilation in necessary). Normally using this task manually is not required, it is called automatically by the `atomvm.pico.flash` if a uf2 file has not already been created.

The `atomvm` properties list in the Mix project file (`mix.exs`) may contain the following entries related to this task:

| Key | Type | Default | Value |
|-----|------|----------|-------|
| `app_start` | Address in hexademical format | 0x10180000 | The flash address to place the application |

Properties in the `mix.exs` file may be over-ridden on the command line using long-style flags (prefixed by `--`) by the same name as the properties key.  For example, you can use the `--app_start` option to specify or override the `app_start` property in the above table.