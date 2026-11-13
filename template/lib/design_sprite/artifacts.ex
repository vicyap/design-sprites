defmodule DesignSprite.Artifacts do
  @moduledoc """
  Design artifacts: standalone HTML files under artifacts/, versioned
  like every Project file (contract item 6).

  - The AI generates an artifact; every edit is a NEW version —
    history kept, latest paramount.
  - Edits are PATCHES, not regenerations: a patch names an exact,
    unique substring of the current version's bytes and its
    replacement. The rest of the page survives byte-for-byte, so
    anchors and already-approved parts cannot drift.
  - An existing page enters as a SNAPSHOT: its HTML is stored as
    version 0, and the first edit (patch or regeneration) becomes
    version 1 like any other artifact's.
  """

  alias DesignSprite.ProjectFiles

  @dir "artifacts"

  def sanitize_name(name) when is_binary(name) do
    name |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  def sanitize_name(_), do: nil

  def path_for(name), do: "#{@dir}/#{sanitize_name(name)}.html"

  @doc "Names of all artifacts that have at least one recorded version."
  def names do
    ProjectFiles.list()
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.starts_with?(&1, @dir <> "/"))
    |> Enum.map(fn path ->
      path |> String.replace_prefix(@dir <> "/", "") |> String.replace_suffix(".html", "")
    end)
    |> Enum.sort()
  end

  @doc "The latest version's HTML for an artifact, or nil."
  def current_html(name) do
    case ProjectFiles.read(path_for(name)) do
      {:ok, html} -> html
      _ -> nil
    end
  end

  @doc "The latest version number for an artifact, or nil."
  def current_version(name) do
    case Enum.find(ProjectFiles.list(), &(&1.path == path_for(name))) do
      %{version: version} -> version
      nil -> nil
    end
  end

  @doc "All recorded version numbers for an artifact, ascending."
  def version_numbers(name) do
    name
    |> path_for()
    |> ProjectFiles.versions()
    |> Enum.map(& &1.version)
    |> Enum.sort()
  end

  @doc """
  Element-id coverage of an HTML document or fragment: how many
  meaningful elements it carries, and how many of those carry an id.

  Contract item 6 gives artifacts STABLE ELEMENT IDS — the inspector's
  identity for an element is its id; without one it degrades to a CSS
  path that shifts under any edit. "Meaningful" is the semantic /
  interactive tag set an inspector would target (structure, headings,
  links, media, form controls); layout wrappers like <div>/<span> are
  not counted either way.
  """
  @meaningful_tags ~w(a article aside button figure footer form header img input main nav p section select table textarea video)
  @heading_tags ~w(h1 h2 h3 h4 h5 h6)
  @tag_regex Regex.compile!(
               "<\\s*(" <>
                 Enum.join(@meaningful_tags ++ @heading_tags, "|") <> ")(\\s[^>]*)?>",
               "i"
             )
  @id_attr_regex ~r/(?:^|\s)id\s*=/i

  def id_coverage(html) when is_binary(html) do
    tags = Regex.scan(@tag_regex, html)

    identified =
      Enum.count(tags, fn
        # Regex.scan drops a trailing unmatched group, so a bare tag
        # (<p>) scans as a 2-element match with no attrs element.
        [_full, _tag, attrs] -> Regex.match?(@id_attr_regex, attrs || "")
        [_full, _tag] -> false
      end)

    %{meaningful: length(tags), identified: identified}
  end

  @doc """
  The id floor (pilot finding F4): content with fewer than
  `min_meaningful` meaningful elements is trivial and exempt;
  otherwise at least a quarter of the meaningful elements must carry
  ids. A floor, not the standard — the prompt still asks for ids on
  meaningful elements generally; this only refuses the degenerate
  case (a full page with zero ids) that prose instructions missed.
  """
  def ids_sufficient?(html, min_meaningful) do
    %{meaningful: meaningful, identified: identified} = id_coverage(html)
    meaningful < min_meaningful or identified * 4 >= meaningful
  end

  @doc "Full artifact writes: trivial below 4 meaningful elements."
  def artifact_ids_sufficient?(html), do: ids_sufficient?(html, 4)

  @doc "Patch replacements: trivial below 3 meaningful elements."
  def fragment_ids_sufficient?(html), do: ids_sufficient?(html, 3)

  @doc """
  Write a full artifact (first generation, or a new direction the
  Driver asked for). A non-trivial artifact whose meaningful elements
  lack ids is refused at write time — {:error, :artifact_ids_missing},
  nothing stored — because the file on disk is what the inspector
  points at, and an id-less page has no stable points.
  """
  def write_new(name, html, actor) when is_binary(html) do
    if artifact_ids_sufficient?(html) do
      ProjectFiles.write(path_for(name), html, actor)
    else
      {:error, :artifact_ids_missing}
    end
  end

  @doc """
  Enter an existing page as a snapshot: version 0. Only possible
  while the artifact has no versions at all — a snapshot never
  overwrites history.
  """
  def snapshot(name, html, actor) when is_binary(html) do
    if version_numbers(name) == [] do
      ProjectFiles.write_at(path_for(name), html, actor, 0)
    else
      {:error, :artifact_exists}
    end
  end

  @doc """
  Check a patch against the current version WITHOUT writing:
  :ok, or {:error, :no_artifact | :patch_target_not_found |
  :patch_target_not_unique | :patch_invalid}.
  """
  def patch_check(name, find) do
    case validate_patch(name, find) do
      {:ok, _html} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Apply a patch: replace the single occurrence of `find` in the
  current version with `replace`, stored as a new version. A patch
  whose target is missing or ambiguous writes NOTHING — and so does
  a patch whose replacement introduces non-trivial id-less structure
  ({:error, :artifact_ids_missing}): the new bytes are held to the
  same id floor as a full write.
  """
  def patch(name, find, replace, actor) when is_binary(replace) do
    case validate_patch(name, find) do
      {:ok, html} ->
        if fragment_ids_sufficient?(replace) do
          ProjectFiles.write(path_for(name), String.replace(html, find, replace), actor)
        else
          {:error, :artifact_ids_missing}
        end

      {:error, _} = err ->
        err
    end
  end

  defp validate_patch(name, find) do
    cond do
      not is_binary(find) or find == "" ->
        {:error, :patch_invalid}

      true ->
        case current_html(name) do
          nil ->
            {:error, :no_artifact}

          html ->
            case length(String.split(html, find)) - 1 do
              1 -> {:ok, html}
              0 -> {:error, :patch_target_not_found}
              _ -> {:error, :patch_target_not_unique}
            end
        end
    end
  end
end
