if Code.ensure_loaded?(Igniter.Mix.Task) do
defmodule Mix.Tasks.Exatomvm.Install do
  use Igniter.Mix.Task

  @example "mix igniter.new my_project --install exatomvm@github:atomvm/exatomvm && cd my_project"

  @shortdoc "Add and configure AtomVM for your project"
  @moduledoc """
  #{@shortdoc}

  This task sets up your Elixir project to work with AtomVM, adding necessary dependencies
  and configuration for targeting embedded devices like ESP32, Raspberry Pi Pico, and STM32.

  ## Example

  ```bash
  #{@example}
  ```

  """

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :exatomvm,
      # exatomvm is a build-time dependency, so it is only needed on the build host
      dep_opts: [runtime: false],
      adds_deps: [
        {:pythonx, "~> 0.4.0", runtime: false},
        {:req, "~> 0.7.0", runtime: false}
      ],
      example: @example
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    selected_instructions =
      if igniter.args.options[:yes] do
        # Don't prompt in non-interactive runs (e.g. `--yes` or no TTY)
        "All"
      else
        select_device()
      end

    module_name = Igniter.Project.Module.module_name_prefix(igniter)

    options = [
      start: module_name,
      esp32_flash_offset: Sourceror.parse_string!("0x250000"),
      stm32_flash_offset: Sourceror.parse_string!("0x8080000"),
      chip: "auto",
      port: "auto"
    ]

    Igniter.Project.MixProject.update(igniter, :project, [:atomvm], fn _zipper ->
      {:ok, {:code, options}}
    end)
    |> Igniter.mkdir("avm_deps")
    |> Igniter.Project.Module.find_and_update_or_create_module(
      module_name,
      """
      def start do
        IO.inspect("Hello AtomVM!")
        :ok
      end
      """,
      fn zipper ->
        case Igniter.Code.Function.move_to_def(zipper, :start, 0) do
          :error ->
            {:ok,
             Igniter.Code.Common.add_code(
               zipper,
               """
               def start do
                 IO.inspect("Hello AtomVM!")
                 :ok
               end
               """,
               placement: :after
             )}

          _ ->
            {:ok, zipper}
        end
      end
    )
    |> then(fn igniter ->
      template_path = Application.app_dir(:exatomvm, "priv/idf_component.yml.example")

      case File.read(template_path) do
        {:ok, contents} ->
          Igniter.create_new_file(igniter, "idf_component.yml", contents, on_exists: :skip)

        {:error, reason} ->
          Igniter.add_issue(igniter, "Could not read idf_component.yml template: #{inspect(reason)}")
      end
    end)
    |> then(fn igniter ->
      if Igniter.Project.Deps.has_dep?(igniter, :igniter) do
        Igniter.Project.Deps.set_dep_option(igniter, :igniter, :runtime, false)
      else
        igniter
      end
    end)
    |> output_instructions(selected_instructions)
  end

  defp select_device do
    Igniter.Util.IO.select(
      """
      About to configure project for AtomVM!

      Which device would you like to see setup instructions for?
      (Your project will be configured for all devices - this only affects the instructions shown):
      """,
      ["ESP32", "Pico", "STM32", "All"],
      default: "All"
    )
  rescue
    # `Igniter.Util.IO.select/3` raises on closed stdin (e.g. `mix ... < /dev/null`),
    # because igniter's `tty?/0` reports a character device such as `/dev/null` as a tty.
    FunctionClauseError -> "All"
  end

  defp common_intro do
    """
    🎉 Your AtomVM project is now ready!

    Next, you need to install AtomVM itself on your device.

    """
  end

  defp output_instructions(igniter, "ESP32") do
    igniter
    |> Igniter.add_notice("ESP32 Setup Instructions")
    |> Igniter.add_notice("""
    #{common_intro()}
    ## Installing AtomVM on ESP32

    Choose one of these methods:

    1. **Using Mix task (recommended):**
       mix atomvm.esp32.install

    2. **Manual installation:**
       Follow the guide at: https://doc.atomvm.org/main/getting-started-guide.html#flashing-a-binary-image-to-esp32

    3. **Web flasher (Chrome browser only):**
       (Choose the Elixir-enabled build of AtomVM.)
       Visit: https://petermm.github.io/atomvm_flasher

    """)
    |> Igniter.add_notice("""
    ## Flashing Your Project

    Once AtomVM is installed on your device, flash your project with:

    mix atomvm.esp32.flash

    """)
  end

  defp output_instructions(igniter, "Pico") do
    igniter
    |> Igniter.add_notice("Raspberry Pi Pico Setup Instructions")
    |> Igniter.add_notice("""
    #{common_intro()}
    ## Installing AtomVM on Raspberry Pi Pico

    Follow the installation guide at:
    https://doc.atomvm.org/main/getting-started-guide.html#flashing-a-binary-image-to-pico

    """)
    |> Igniter.add_notice("""
    ## Flashing Your Project

    Once AtomVM is installed on your device, flash your project with:

    mix atomvm.pico.flash

    For more details, see: https://github.com/atomvm/exatomvm?tab=readme-ov-file#the-atomvmpicoflash-task
    """)
  end

  defp output_instructions(igniter, "STM32") do
    igniter
    |> Igniter.add_notice("STM32 Setup Instructions")
    |> Igniter.add_notice("""
    #{common_intro()}
    ## Building AtomVM for STM32

    STM32 requires building AtomVM for your specific board:
    https://doc.atomvm.org/main/build-instructions.html#building-for-stm32

    ## Installing st-link

    You'll need st-link installed for flashing:
    - Installation guide: https://github.com/stlink-org/stlink?tab=readme-ov-file#installation
    - Flashing guide: https://doc.atomvm.org/main/getting-started-guide.html#flashing-a-binary-image-to-stm32
    """)
    |> Igniter.add_notice("""
    ## Flashing Your Project

    Once AtomVM is built and installed on your device, flash your project with:

    mix atomvm.stm32.flash

    For more details, see: https://github.com/atomvm/exatomvm?tab=readme-ov-file#the-atomvmstm32flash-task
    """)
  end

  defp output_instructions(igniter, "All") do
    igniter
    |> output_instructions("ESP32")
    |> output_instructions("Pico")
    |> output_instructions("STM32")
  end

  defp output_instructions(igniter, _), do: igniter
end
end
