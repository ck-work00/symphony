defmodule SymphonyElixir.Workflow.StageLoader do
  @moduledoc """
  Loads and assembles staged workflow prompts from `workflow/stages/` directory.

  Files with `_` prefix are partials (included by others, not standalone stages).
  Files with numeric prefix are ordered stages.
  """

  require Logger

  @doc """
  Reads all `.md` files from the stages directory.
  Returns `%{filename => content}`.
  """
  @spec load_stages(Path.t()) :: %{String.t() => String.t()}
  def load_stages(stages_dir) do
    case File.ls(stages_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.reduce(%{}, fn filename, acc ->
          path = Path.join(stages_dir, filename)

          case File.read(path) do
            {:ok, content} -> Map.put(acc, filename, content)
            {:error, _} -> acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Assembles a full prompt from loaded stages.
  Concatenates `_preamble.md` + numbered stages (00-XX) in order.
  """
  @spec assemble_prompt(%{String.t() => String.t()}) :: String.t()
  def assemble_prompt(stages) when map_size(stages) == 0, do: ""

  def assemble_prompt(stages) do
    preamble = Map.get(stages, "_preamble.md", "")

    numbered =
      stages
      |> Enum.filter(fn {name, _} -> Regex.match?(~r/^\d/, name) end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, content} -> content end)

    partials =
      stages
      |> Enum.filter(fn {name, _} ->
        String.starts_with?(name, "_") and name != "_preamble.md" and name != "_continuation.md"
      end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, content} -> content end)

    [preamble | numbered ++ partials]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n---\n\n")
    |> String.trim()
  end

  @doc """
  Renders a continuation prompt from `_continuation.md` template.
  Falls back to nil if no template exists.
  """
  @spec assemble_continuation(%{String.t() => String.t()}, pos_integer(), pos_integer(), [map()]) ::
          String.t() | nil
  def assemble_continuation(stages, turn_number, max_turns, comments) do
    case Map.get(stages, "_continuation.md") do
      nil ->
        nil

      template ->
        template
        |> String.replace("{{turn_number}}", to_string(turn_number))
        |> String.replace("{{max_turns}}", to_string(max_turns))
        |> String.replace("{{comments_section}}", format_comments(comments))
    end
  end

  defp format_comments([]), do: ""

  defp format_comments(comments) do
    formatted =
      comments
      |> Enum.map(fn c ->
        time = if c[:created_at], do: Calendar.strftime(c.created_at, "%H:%M UTC"), else: "?"
        "  [#{time}] #{c[:author]}: #{c[:body]}"
      end)
      |> Enum.join("\n")

    """

    ## New comments on the Linear issue (from your team — read carefully and follow any instructions):
    #{formatted}

    """
  end

  @doc """
  Computes a stamp for the stages directory based on file mtimes and hashes.
  """
  @spec directory_stamp(Path.t()) :: {:ok, term()} | {:error, term()}
  def directory_stamp(stages_dir) do
    case File.ls(stages_dir) do
      {:ok, files} ->
        md_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort()

        stamps =
          Enum.map(md_files, fn filename ->
            path = Path.join(stages_dir, filename)

            case File.stat(path, time: :posix) do
              {:ok, stat} -> {filename, stat.mtime, stat.size}
              {:error, _} -> {filename, 0, 0}
            end
          end)

        {:ok, :erlang.phash2(stamps)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
