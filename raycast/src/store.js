"use strict";

// The store: every extension in raycast/extensions, searched by name, with
// Install (or Remove, for one already here) as its action. It is drawn with
// the same @raycast/api components extensions use, so Nanolight shows it
// like any command. The names are one request (github.js `listAll`); the
// rows on screen get their titles, descriptions and icons from each
// package.json on raw.githubusercontent.com, which the API limit doesn't
// count. An install tells Nanolight `{"type":"installed"}` to list its
// commands among the apps.

const fs = require("fs");
const path = require("path");
const React = require("react");
const api = require("./api");
const { send } = require("./protocol");
const github = require("./github");
const { installExtension, removeExtension } = require("./install");

const h = React.createElement;
const { List, ActionPanel, Action, showToast, Toast } = api;

/// Extensions people reach for first, shown before anything is typed.
const popular = ["hacker-news", "dad-jokes", "github", "spotify-player", "google-translate", "color-picker", "brew", "kill-process", "coffee", "random-data-generator", "lorem-ipsum", "timers"];

function titleOf(name) {
  return name.split("-").map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w)).join(" ");
}

/// Names for `query`: the popular ones when empty, else every name with
/// all its words, best (starting with the query) first.
function matches(names, query, max) {
  const q = query.trim().toLowerCase();
  if (!q) return popular.filter((n) => names.includes(n)).slice(0, max);
  const words = q.split(/\s+/);
  const hits = names.filter((n) => words.every((w) => n.includes(w.replace(/\s+/g, "-"))));
  hits.sort((a, b) => (b.startsWith(q) ? 1 : 0) - (a.startsWith(q) ? 1 : 0) || a.length - b.length);
  return hits.slice(0, max);
}

function Store({ dir }) {
  const [names, setNames] = React.useState(null);
  const [query, setQuery] = React.useState("");
  const [meta, setMeta] = React.useState({});
  const [installed, setInstalled] = React.useState(() => new Set(fs.existsSync(dir) ? fs.readdirSync(dir).filter((n) => !n.startsWith(".")) : []));
  const [busy, setBusy] = React.useState(null);

  React.useEffect(() => {
    github.listAll(path.join(dir, ".cache")).then(setNames, (err) => {
      setNames([]);
      showToast({ style: Toast.Style.Failure, title: "The store didn't load", message: err.message });
    });
  }, []);

  const shown = names ? matches(names, query, 30) : [];
  React.useEffect(() => {
    for (const n of shown) {
      if (meta[n] !== undefined) continue;
      meta[n] = null;
      github.manifest(n).then(
        (pkg) => setMeta((m) => Object.assign({}, m, { [n]: pkg })),
        () => setMeta((m) => Object.assign({}, m, { [n]: false })),
      );
    }
  }, [shown.join(",")]);

  async function install(n) {
    setBusy(n);
    const toast = await showToast({ style: Toast.Style.Animated, title: "Installing " + titleOf(n) + "…" });
    try {
      const r = await installExtension(n, dir);
      setInstalled((s) => new Set(s).add(n));
      toast.style = Toast.Style.Success;
      toast.title = r.title + " is installed";
      toast.message = r.commands.map((c) => c.title).join(", ");
      send({ type: "installed", name: n });
    } catch (err) {
      toast.style = Toast.Style.Failure;
      toast.title = "Couldn't install " + titleOf(n);
      toast.message = err.message;
    }
    setBusy(null);
  }

  function remove(n) {
    removeExtension(n, dir);
    setInstalled((s) => {
      const t = new Set(s);
      t.delete(n);
      return t;
    });
    send({ type: "installed", name: n });
    showToast({ style: Toast.Style.Success, title: titleOf(n) + " is removed" });
  }

  return h(
    List,
    {
      isLoading: names === null || busy !== null,
      searchBarPlaceholder: "Search the Raycast Store…",
      onSearchTextChange: setQuery,
      throttle: true,
    },
    h(
      List.Section,
      { title: query ? "Extensions" : "Popular" },
      shown.map((n) => {
        const pkg = meta[n] || null;
        const here = installed.has(n);
        return h(List.Item, {
          key: n,
          id: n,
          title: (pkg && pkg.title) || titleOf(n),
          subtitle: (pkg && pkg.description) || "",
          icon: pkg && pkg.icon ? { source: github.iconUrl(n, pkg.icon) } : undefined,
          accessories: here ? [{ text: "Installed" }] : pkg && pkg.author ? [{ text: pkg.author }] : [],
          actions: h(
            ActionPanel,
            null,
            here ? h(Action, { title: "Remove", onAction: () => remove(n) }) : h(Action, { title: "Install", onAction: () => install(n) }),
            h(Action.OpenInBrowser, { title: "Open in GitHub", url: "https://github.com/raycast/extensions/tree/main/extensions/" + n }),
          ),
        });
      }),
    ),
  );
}

module.exports = { Store, matches, titleOf };
