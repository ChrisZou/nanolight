import { Action, ActionPanel, Detail, List, getPreferenceValues } from "@raycast/api";
import { useEffect, useState } from "react";

type Prefs = { greeting?: string };

const ITEMS = [
  { id: "alpha", title: "Alpha Story", subtitle: "first", keywords: ["news"] },
  { id: "beta", title: "Beta Notes", subtitle: "second", keywords: ["docs"] },
  { id: "gamma", title: "Gamma", subtitle: "third", keywords: ["other"] },
];

export default function Command() {
  const prefs = getPreferenceValues<Prefs>();
  const [ready, setReady] = useState(false);
  useEffect(() => {
    setReady(true);
  }, []);
  return (
    <List isLoading={!ready} navigationTitle={prefs.greeting || "Demo"} searchBarPlaceholder="Search items">
      <List.Section title="Stories">
        {ITEMS.map((item) => (
          <List.Item
            key={item.id}
            id={item.id}
            title={item.title}
            subtitle={item.subtitle}
            keywords={item.keywords}
            icon="🔥"
            accessories={[{ text: item.keywords[0] }]}
            actions={
              <ActionPanel>
                <Action.Push title="Open Detail" target={<Detail markdown={"# " + item.title} navigationTitle={item.title} />} />
                <Action.CopyToClipboard title="Copy Title" content={item.title} />
                <Action.OpenInBrowser title="Open Site" url={"https://example.com/" + item.id} />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
