ExUnit.start(exclude: if(Code.ensure_loaded?(:json), do: [], else: [:manifest]))
