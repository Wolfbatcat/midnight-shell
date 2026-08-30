pragma Singleton

import ".."
import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.services
import qs.utils

Searcher {
    id: root

    function transformSearch(search: string): string {
        return search.slice(`${GlobalConfig.launcher.actionPrefix}variant `.length);
    }

    function previewVariant(variant: string): void {
        // Build a throwaway Scheme instance instead of mutating the real
        // get_scheme() singleton - its variant setter/update_colours() both
        // call self.save(), which writes scheme.json for real. That turned
        // "preview" into a live, unlocked, racy write to persisted state:
        // just opening this menu (currentItem defaults to index 0) silently
        // overwrote the active variant, and rapid hover navigation could
        // stomp an explicit selection made moments later. Scheme(dict)'s
        // constructor sets _variant directly (bypassing the setter), and
        // _update_colours() (private, no save()) recomputes colours read-only.
        const cmd = `import json\nfrom caelestia.utils.scheme import get_scheme, Scheme\ncurrent = get_scheme()\npreview = Scheme({"name": current.name, "flavour": current.flavour, "mode": current.mode, "variant": "${variant}", "colours": current.colours})\npreview._update_colours()\nprint(json.dumps({"name": preview.name, "flavour": preview.flavour, "mode": preview.mode, "variant": preview.variant, "colours": preview.colours}))`;
        getPreviewColoursProc.command = ["python3", "-c", cmd];
        getPreviewColoursProc.running = true;
    }

    Process {
        id: getPreviewColoursProc
        stdout: StdioCollector {
            onStreamFinished: {
                Colours.load(text, true);
                Colours.showPreview = true;
            }
        }
    }

    list: [
        Variant {
            variant: "vibrant"
            icon: "sentiment_very_dissatisfied"
            name: qsTr("Vibrant")
            description: qsTr("A high chroma palette. The primary palette's chroma is at maximum.")
        },
        Variant {
            variant: "vibrant-bbc"
            icon: "sentiment_very_dissatisfied"
            name: qsTr("True Vibrant")
            description: qsTr("A high chroma palette. Like Vibrant, but secondary and tertiary hues are pulled back toward the seed colour instead of swinging wide across the wheel.")
        },
        Variant {
            variant: "tonalspot"
            icon: "android"
            name: qsTr("Tonal Spot")
            description: qsTr("Default for Material theme colours. A pastel palette with a low chroma.")
        },
        Variant {
            variant: "expressive"
            icon: "compare_arrows"
            name: qsTr("Expressive")
            description: qsTr("A medium chroma palette. The primary palette's hue is different from the seed colour, for variety.")
        },
        Variant {
            variant: "expressive-bbc"
            icon: "compare_arrows"
            name: qsTr("True Expressive")
            description: qsTr("A medium chroma palette. Like Expressive, but secondary and tertiary hues are pulled back toward the seed colour instead of swinging wide across the wheel.")
        },
        Variant {
            variant: "fidelity"
            icon: "compare"
            name: qsTr("Fidelity")
            description: qsTr("Matches the seed colour, even if the seed colour is very bright (high chroma).")
        },
        Variant {
            variant: "content"
            icon: "sentiment_calm"
            name: qsTr("Content")
            description: qsTr("Almost identical to fidelity.")
        },
        Variant {
            variant: "fruitsalad"
            icon: "nutrition"
            name: qsTr("Fruit Salad")
            description: qsTr("A playful theme - the seed colour's hue does not appear in the theme.")
        },
        Variant {
            variant: "rainbow"
            icon: "looks"
            name: qsTr("Rainbow")
            description: qsTr("A playful theme - the seed colour's hue does not appear in the theme.")
        },
        Variant {
            variant: "neutral"
            icon: "contrast"
            name: qsTr("Neutral")
            description: qsTr("Close to grayscale, a hint of chroma.")
        },
        Variant {
            variant: "monochrome"
            icon: "filter_b_and_w"
            name: qsTr("Monochrome")
            description: qsTr("All colours are grayscale, no chroma.")
        }
    ]
    useFuzzy: GlobalConfig.launcher.useFuzzy.variants

    component Variant: QtObject {
        required property string variant
        required property string icon
        required property string name
        required property string description

        function onClicked(list: AppList): void {
            list.screenState.launcher = false;
            Quickshell.execDetached(["caelestia", "scheme", "set", "-v", variant]);
        }
    }
}
