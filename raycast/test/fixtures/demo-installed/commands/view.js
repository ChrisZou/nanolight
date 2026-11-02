var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/view.tsx
var view_exports = {};
__export(view_exports, {
  default: () => Command
});
module.exports = __toCommonJS(view_exports);
var import_api = require("@raycast/api");
var import_react = require("react");
var import_jsx_runtime = require("react/jsx-runtime");
var ITEMS = [
  { id: "alpha", title: "Alpha Story", subtitle: "first", keywords: ["news"] },
  { id: "beta", title: "Beta Notes", subtitle: "second", keywords: ["docs"] },
  { id: "gamma", title: "Gamma", subtitle: "third", keywords: ["other"] }
];
function Command() {
  const prefs = (0, import_api.getPreferenceValues)();
  const [ready, setReady] = (0, import_react.useState)(false);
  (0, import_react.useEffect)(() => {
    setReady(true);
  }, []);
  return /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_api.List, { isLoading: !ready, navigationTitle: prefs.greeting || "Demo", searchBarPlaceholder: "Search items", children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_api.List.Section, { title: "Stories", children: ITEMS.map((item) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)(
    import_api.List.Item,
    {
      id: item.id,
      title: item.title,
      subtitle: item.subtitle,
      keywords: item.keywords,
      icon: "\u{1F525}",
      accessories: [{ text: item.keywords[0] }],
      actions: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(import_api.ActionPanel, { children: [
        /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_api.Action.Push, { title: "Open Detail", target: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_api.Detail, { markdown: "# " + item.title, navigationTitle: item.title }) }),
        /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_api.Action.CopyToClipboard, { title: "Copy Title", content: item.title }),
        /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_api.Action.OpenInBrowser, { title: "Open Site", url: "https://example.com/" + item.id })
      ] })
    },
    item.id
  )) }) });
}
