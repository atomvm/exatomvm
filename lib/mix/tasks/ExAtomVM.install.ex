defmodule Mix.Tasks.Exatomvm.Install do
  use Igniter.Mix.Task

  @example "mix igniter.new my_project --install exatomvm@github:atomvm/exatomvm && cd my_project"

  @shortdoc "Add and config AtomVM"
  @moduledoc """
  #{@shortdoc}

  ## Example

  ```bash
  #{@example}
  ```

  """

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      # Groups allow for overlapping arguments for tasks by the same author
      # See the generators guide for more.
      group: :exatomvm,
      # dependencies to add
      adds_deps: [],
      # dependencies to add and call their associated installers, if they exist
      installs: [],
      # An example invocation
      example: @example,
      # A list of environments that this should be installed in.
      only: nil,
      # a list of positional arguments, i.e `[:file]`
      positional: [],
      # Other tasks your task composes using `Igniter.compose_task`, passing in the CLI argv
      # This ensures your option schema includes options from nested tasks
      composes: [],
      # `OptionParser` schema
      schema: [],
      # Default values for the options in the `schema`
      defaults: [],
      # CLI aliases
      aliases: [],
      # A list of options in the schema that are required
      required: []
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.update_elixir_file(igniter, "mix.exs", fn zipper ->
      with {:ok, zipper} <- Igniter.Code.Function.move_to_def(zipper, :project, 0),
           {:ok, zipper} <-
             Igniter.Code.Keyword.put_in_keyword(
               zipper,
               [:atomvm],
               start: Igniter.Project.Module.module_name_prefix(igniter),
               esp32_flash_offset: Sourceror.parse_string!("0x250000"),
               stm32_flash_offset: Sourceror.parse_string!("0x8080000"),
               chip: "auto",
               port: "auto"
             ) do
        {:ok, zipper}
      end
    end)
    |> Igniter.Project.Module.find_and_update_module!(
      Igniter.Project.Module.module_name_prefix(igniter),
      fn zipper ->
        case Igniter.Code.Function.move_to_def(zipper, :start, 0) do
          :error ->
            # start not available
            zipper =
              Igniter.Code.Common.add_code(
                zipper,
                """
                def start do
                  IO.inspect("Hello AtomVM!")
                  :ok
                end
                """,
                :before
              )

            {:ok, zipper}

          _ ->
            {:ok, zipper}
        end
      end
    )
  end
end
