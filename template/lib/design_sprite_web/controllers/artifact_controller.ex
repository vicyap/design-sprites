defmodule DesignSpriteWeb.ArtifactController do
  @moduledoc """
  Serves an artifact file as raw HTML for the pane's sandboxed
  iframe — the latest version, or a specific version at
  /artifact/:name/v/:version.

  THE INSPECTOR: the served bytes carry an injected bridge script
  (the stored file bytes are never modified — injection happens at
  serve time only, so every version in history stays exactly as it
  was written). The bridge makes the artifact clickable:

  - clicking an element outlines it and posts a descriptor to the
    parent window: {type: "ds-element", element: {tag, id, classes,
    text, path, snippet, artifact}} — the parent's Composer hook
    forwards it to the LiveView, which attaches it to the chat
    composer as a chip (contract item 6);
  - identity is stable: the element's own id when it has one,
    otherwise a CSS path of tag:nth-of-type segments from <body>,
    so the same element resolves to the same descriptor on every
    version whose structure keeps it in place;
  - anchor clicks are captured (a design mockup's links go nowhere),
    everything else is left to the artifact.
  """
  use DesignSpriteWeb, :controller

  alias DesignSprite.{Artifacts, ProjectFiles}

  def show(conn, %{"name" => name}) do
    serve(conn, name, :latest)
  end

  def show_version(conn, %{"name" => name, "version" => version}) do
    case Integer.parse(version) do
      {n, ""} when n >= 0 -> serve(conn, name, n)
      _ -> conn |> put_status(404) |> text("no such version")
    end
  end

  defp serve(conn, name, version) do
    safe = Artifacts.sanitize_name(name)

    result =
      case version do
        :latest -> ProjectFiles.read(Artifacts.path_for(safe))
        n -> ProjectFiles.read(Artifacts.path_for(safe), n)
      end

    case result do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, inject(html, safe))

      _ ->
        conn |> put_status(404) |> text("no such artifact")
    end
  end

  @marker "data-ds-inspector"

  @doc "The inspector bridge, injected at serve time unless already present."
  def inject(html, name) do
    if String.contains?(html, @marker) do
      html
    else
      script = bridge_script(name)

      case Regex.run(~r/<\/body\s*>/i, html, return: :index) do
        [{idx, len}] ->
          # Regex indices are byte offsets — slice as binary.
          <<before::binary-size(idx), rest::binary>> = html
          <<tag::binary-size(len), after_tag::binary>> = rest
          before <> script <> tag <> after_tag

        _ ->
          html <> script
      end
    end
  end

  defp bridge_script(name) do
    """
    <script #{@marker} data-artifact="#{name}">
    (function () {
      var ARTIFACT = #{JSON.encode!(name)};
      var last = null;
      function pathOf(el) {
        var parts = [];
        var node = el;
        while (node && node !== document.body && node.nodeType === 1) {
          var tag = node.tagName.toLowerCase();
          var parent = node.parentElement;
          if (parent) {
            var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === node.tagName; });
            if (same.length > 1) tag += ":nth-of-type(" + (same.indexOf(node) + 1) + ")";
          }
          parts.unshift(tag);
          node = parent;
        }
        return parts.join(" > ");
      }
      function describe(el) {
        var text = (el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 120);
        return {
          tag: el.tagName.toLowerCase(),
          id: el.id || "",
          classes: typeof el.className === "string" ? el.className : "",
          text: text,
          path: pathOf(el),
          snippet: (el.outerHTML || "").slice(0, 200),
          artifact: ARTIFACT
        };
      }
      function outline(el) {
        if (last) { last.style.outline = last.__dsPrevOutline || ""; last.style.outlineOffset = ""; }
        last = el;
        if (el) {
          el.__dsPrevOutline = el.style.outline || "";
          el.style.outline = "2px solid #b98a1c";
          el.style.outlineOffset = "1px";
        }
      }
      document.addEventListener("mouseover", function (ev) {
        if (ev.target && ev.target !== last) {
          ev.target.style.cursor = "pointer";
        }
      }, true);
      document.addEventListener("click", function (ev) {
        var el = ev.target;
        if (!el || el.nodeType !== 1 || el === document.body || el === document.documentElement) return;
        if (el.closest("a")) ev.preventDefault();
        outline(el);
        window.parent.postMessage({ type: "ds-element", element: describe(el) }, "*");
      }, true);
    })();
    </script>
    """
  end
end
