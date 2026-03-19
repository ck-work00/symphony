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
        String.starts_with?(name, "_") and name not in ["_preamble.md", "_continuation.md", "_retask.md"]
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
  Extracts the content section for a specific workflow phase from loaded stages.

  Phases map to stage file sections by their `SYMPHONY_PHASE: <Name>` markers.
  Returns the content from the marker through to the next marker or end of file.
  """
  @spec phase_content(%{String.t() => String.t()}, String.t()) :: String.t() | nil
  def phase_content(stages, phase_name) do
    # Search all numbered stage files for the phase marker
    stages
    |> Enum.filter(fn {name, _} -> Regex.match?(~r/^\d/, name) end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.reduce(nil, fn {_name, content}, acc ->
      acc || extract_phase_section(content, phase_name)
    end)
  end

  defp extract_phase_section(content, phase_name) do
    marker = "SYMPHONY_PHASE: #{phase_name}"

    if String.contains?(content, marker) do
      content
      |> String.split("\n")
      |> find_phase_lines(marker, false, [])
      |> case do
        [] -> nil
        lines -> Enum.join(lines, "\n") |> String.trim()
      end
    else
      nil
    end
  end

  # Walk lines, collecting from the marker's heading through to the next SYMPHONY_PHASE marker
  defp find_phase_lines([], _marker, _collecting, acc), do: Enum.reverse(acc)

  defp find_phase_lines([line | rest], marker, false, acc) do
    if String.contains?(line, marker) do
      # Find the heading line before this marker (look back in acc or use the line before)
      find_phase_lines(rest, marker, true, [line | acc])
    else
      find_phase_lines(rest, marker, false, acc)
    end
  end

  defp find_phase_lines([line | rest], marker, true, acc) do
    if String.contains?(line, "SYMPHONY_PHASE:") and not String.contains?(line, marker) do
      # Hit the next phase marker — stop collecting but include the heading
      # (the heading belongs to the next phase, so don't include this line)
      Enum.reverse(acc)
    else
      find_phase_lines(rest, marker, true, [line | acc])
    end
  end

  @doc """
  Loads the retask template from `_retask.md` in the stages directory.
  Returns nil if no template exists.
  """
  @spec load_retask_template(Path.t()) :: String.t() | nil
  def load_retask_template(stages_dir) do
    path = Path.join(stages_dir, "_retask.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
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
