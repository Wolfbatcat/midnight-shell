pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.utils
import Caelestia

Singleton {
    id: root

    property var events: []
    property bool loaded: false
    property bool loading: false
    property string icsUrl: ""

    readonly property var dayNames: ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    // Window to expand recurring events into concrete days: generous enough
    // for a dashboard month-grid widget, bounded so a pathological/unbounded
    // RRULE can't loop forever.
    readonly property int windowPastDays: 90
    readonly property int windowFutureDays: 400
    readonly property int maxIterationsPerEvent: 2000

    FileView {
        id: configFile
        path: `${Paths.config}/google-calendar.json`
        onLoaded: {
            try {
                const cfg = JSON.parse(text());
                root.icsUrl = cfg.icsUrl || "";
            } catch (e) {
                console.warn("GoogleCalendar: failed to parse google-calendar.json:", e);
            }
            if (root.icsUrl)
                root.reload();
        }
        onLoadFailed: console.warn("GoogleCalendar: no ~/.config/caelestia/google-calendar.json - dashboard calendar events disabled")
    }

    function reload(): void {
        if (loading || !icsUrl)
            return;
        loading = true;

        Requests.get(icsUrl, text => {
            loading = false;
            try {
                events = parseIcs(text);
                loaded = true;
                retryTimer.stop();
            } catch (e) {
                console.error("Failed to parse Google Calendar events:", e);
                retryTimer.restart();
            }
        }, err => {
            loading = false;
            console.warn("Failed to fetch Google Calendar events:", err);
            retryTimer.restart();
        });
    }

    Connections {
        target: Nmcli
        function onIsConnectedChanged() {
            if (Nmcli.isConnected && !root.loaded && root.icsUrl)
                root.reload();
        }
    }

    Timer {
        id: retryTimer
        interval: 30000
        repeat: true
        onTriggered: root.reload()
    }

    // A real calendar changes far more often than a fixed holiday list -
    // refetch periodically so new/changed events show up without a shell
    // restart.
    Timer {
        interval: 3600000 // 1 hour
        repeat: true
        running: true
        onTriggered: root.reload()
    }

    // ---- ICS (RFC5545) parsing ----
    //
    // Deliberately not a full RFC5545 implementation. Scoped against a real
    // exported Google Calendar feed: handles VEVENT SUMMARY/DTSTART (plain,
    // VALUE=DATE, or TZID), RRULE for FREQ=DAILY/WEEKLY/MONTHLY/YEARLY with
    // INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY, EXDATE exclusions, and
    // RECURRENCE-ID overrides (rescheduled/cancelled single instances of a
    // recurring event). Not handled: MONTHLY BYDAY ("2nd Tuesday" style),
    // WEEKLY BYDAY combined with INTERVAL>1 (treated as every matching week,
    // interval ignored), and general VALARM/attendee/etc. data - none of
    // that is needed for a day-granularity dashboard dot indicator.
    //
    // Dates are read as literal wall-clock numbers from the ICS text (TZID
    // param, if present, is not resolved through a timezone database) - this
    // is deliberate, not a shortcut: it gives the correct calendar day an
    // event falls on in whatever zone it was created in, which is exactly
    // what a day-granularity widget needs, without needing an IANA tz
    // database in QML.

    function pad2(n: int): string {
        return n < 10 ? `0${n}` : `${n}`;
    }

    function dayString(date: date): string {
        return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
    }

    function unfold(text: string): var {
        const raw = text.split(/\r\n|\n|\r/);
        const out = [];
        for (const line of raw) {
            if ((line.startsWith(" ") || line.startsWith("\t")) && out.length > 0) {
                out[out.length - 1] += line.slice(1);
            } else {
                out.push(line);
            }
        }
        return out;
    }

    function extractBlocks(lines: var, name: string): var {
        const blocks = [];
        let current = null;
        for (const line of lines) {
            if (line === `BEGIN:${name}`) {
                current = [];
            } else if (line === `END:${name}`) {
                if (current)
                    blocks.push(current);
                current = null;
            } else if (current) {
                current.push(line);
            }
        }
        return blocks;
    }

    function splitProp(line: string): var {
        const colonIdx = line.indexOf(":");
        if (colonIdx === -1)
            return null;
        const head = line.slice(0, colonIdx);
        const value = line.slice(colonIdx + 1);
        const parts = head.split(";");
        const name = parts[0];
        const params = {};
        for (let i = 1; i < parts.length; i++) {
            const eqIdx = parts[i].indexOf("=");
            if (eqIdx === -1)
                continue;
            params[parts[i].slice(0, eqIdx)] = parts[i].slice(eqIdx + 1);
        }
        return { name, params, value };
    }

    function parseDateTime(value: string, params: var): var {
        if (params && params.VALUE === "DATE") {
            const y = parseInt(value.slice(0, 4), 10);
            const mo = parseInt(value.slice(4, 6), 10) - 1;
            const d = parseInt(value.slice(6, 8), 10);
            return { date: new Date(y, mo, d), wallClock: value };
        }

        const m = value.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$/);
        if (!m)
            return null;
        const y = parseInt(m[1], 10);
        const mo = parseInt(m[2], 10) - 1;
        const d = parseInt(m[3], 10);
        const h = parseInt(m[4], 10);
        const mi = parseInt(m[5], 10);
        const s = parseInt(m[6], 10);
        return { date: new Date(y, mo, d, h, mi, s), wallClock: `${m[1]}${m[2]}${m[3]}T${m[4]}${m[5]}${m[6]}` };
    }

    function unescapeText(s: string): string {
        return s.replace(/\\n/gi, " ").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\");
    }

    function parseRrule(value: string): var {
        const rule = {};
        for (const part of value.split(";")) {
            const eqIdx = part.indexOf("=");
            if (eqIdx === -1)
                continue;
            rule[part.slice(0, eqIdx)] = part.slice(eqIdx + 1);
        }
        return rule;
    }

    function parseVevent(lines: var): var {
        let summary = "";
        let uid = "";
        let dtstart = null;
        let rrule = null;
        let recurrenceId = null;
        let status = "";
        const exdates = [];

        for (const line of lines) {
            const prop = splitProp(line);
            if (!prop)
                continue;

            if (prop.name === "SUMMARY") {
                summary = unescapeText(prop.value);
            } else if (prop.name === "UID") {
                uid = prop.value;
            } else if (prop.name === "DTSTART") {
                const parsed = parseDateTime(prop.value, prop.params);
                if (parsed)
                    dtstart = parsed;
            } else if (prop.name === "RRULE") {
                rrule = parseRrule(prop.value);
            } else if (prop.name === "RECURRENCE-ID") {
                const parsed = parseDateTime(prop.value, prop.params);
                if (parsed)
                    recurrenceId = parsed.wallClock;
            } else if (prop.name === "STATUS") {
                status = prop.value;
            } else if (prop.name === "EXDATE") {
                for (const v of prop.value.split(",")) {
                    const parsed = parseDateTime(v, prop.params);
                    if (parsed)
                        exdates.push(parsed.wallClock);
                }
            }
        }

        if (!dtstart && !recurrenceId)
            return null;

        return { summary, uid, dtstart, rrule, recurrenceId, status, exdates };
    }

    function expandRrule(ev: var, windowStart: date, windowEnd: date, excludedWallClocks: var): var {
        const rule = ev.rrule;
        const freq = rule.FREQ;
        if (!ev.dtstart || !freq)
            return [];

        const interval = rule.INTERVAL ? parseInt(rule.INTERVAL, 10) : 1;
        const count = rule.COUNT ? parseInt(rule.COUNT, 10) : null;
        let until = null;
        if (rule.UNTIL) {
            const parsedUntil = parseDateTime(rule.UNTIL, rule.UNTIL.length === 8 ? { VALUE: "DATE" } : null);
            if (parsedUntil)
                until = parsedUntil.date;
        }
        const byDay = rule.BYDAY ? rule.BYDAY.split(",") : null;
        const byMonthDay = rule.BYMONTHDAY ? rule.BYMONTHDAY.split(",").map(n => parseInt(n, 10)) : null;

        const h = ev.dtstart.date.getHours(), mi = ev.dtstart.date.getMinutes(), s = ev.dtstart.date.getSeconds();
        const results = [];
        let occurrenceCount = 0;

        // Returns true to keep going, "stop" to halt expansion entirely.
        function accept(d) {
            const candidate = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, mi, s);
            if (candidate < ev.dtstart.date)
                return true; // before the series actually starts, not an occurrence
            if (until && candidate > until)
                return "stop";
            occurrenceCount++;
            if (count !== null && occurrenceCount > count)
                return "stop";
            if (candidate >= windowStart && candidate <= windowEnd) {
                const wallClock = `${candidate.getFullYear()}${pad2(candidate.getMonth() + 1)}${pad2(candidate.getDate())}T${pad2(h)}${pad2(mi)}${pad2(s)}`;
                if (!excludedWallClocks.has(wallClock))
                    results.push(candidate);
            }
            return true;
        }

        let iterations = 0;
        const noHardLimit = until === null && count === null;

        if (freq === "DAILY") {
            let cursor = new Date(ev.dtstart.date.getFullYear(), ev.dtstart.date.getMonth(), ev.dtstart.date.getDate());
            while (iterations++ < maxIterationsPerEvent) {
                if (accept(cursor) === "stop")
                    break;
                if (noHardLimit && cursor > windowEnd)
                    break;
                cursor.setDate(cursor.getDate() + interval);
            }
        } else if (freq === "WEEKLY") {
            const days = byDay ? byDay.map(bd => dayNames.indexOf(bd.slice(-2))).filter(i => i >= 0) : [ev.dtstart.date.getDay()];
            days.sort((a, b) => a - b);
            let weekStart = new Date(ev.dtstart.date.getFullYear(), ev.dtstart.date.getMonth(), ev.dtstart.date.getDate());
            weekStart.setDate(weekStart.getDate() - weekStart.getDay());
            outerWeekly: while (iterations++ < maxIterationsPerEvent) {
                for (const dow of days) {
                    const cand = new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + dow);
                    if (accept(cand) === "stop")
                        break outerWeekly;
                }
                if (noHardLimit && weekStart > windowEnd)
                    break;
                weekStart.setDate(weekStart.getDate() + 7 * interval);
            }
        } else if (freq === "MONTHLY") {
            let monthCursor = new Date(ev.dtstart.date.getFullYear(), ev.dtstart.date.getMonth(), 1);
            const daysOfMonth = byMonthDay || [ev.dtstart.date.getDate()];
            outerMonthly: while (iterations++ < maxIterationsPerEvent) {
                const daysInMonth = new Date(monthCursor.getFullYear(), monthCursor.getMonth() + 1, 0).getDate();
                const candidates = daysOfMonth.map(dom => {
                    const day = dom > 0 ? dom : daysInMonth + dom + 1;
                    return (day >= 1 && day <= daysInMonth) ? new Date(monthCursor.getFullYear(), monthCursor.getMonth(), day) : null;
                }).filter(d => d).sort((a, b) => a - b);

                for (const cand of candidates) {
                    if (accept(cand) === "stop")
                        break outerMonthly;
                }
                if (noHardLimit && monthCursor > windowEnd)
                    break;
                monthCursor.setMonth(monthCursor.getMonth() + interval);
            }
        } else if (freq === "YEARLY") {
            let cursor = new Date(ev.dtstart.date.getFullYear(), ev.dtstart.date.getMonth(), ev.dtstart.date.getDate());
            while (iterations++ < maxIterationsPerEvent) {
                if (accept(cursor) === "stop")
                    break;
                if (noHardLimit && cursor > windowEnd)
                    break;
                cursor.setFullYear(cursor.getFullYear() + interval);
            }
        }

        return results;
    }

    function parseIcs(text: string): var {
        const lines = unfold(text);
        const veventBlocks = extractBlocks(lines, "VEVENT");

        const masters = [];
        const overrides = [];

        for (const block of veventBlocks) {
            const ev = parseVevent(block);
            if (!ev)
                continue;
            if (ev.recurrenceId)
                overrides.push(ev);
            else
                masters.push(ev);
        }

        const overridesByUid = new Map();
        for (const ov of overrides) {
            if (!overridesByUid.has(ov.uid))
                overridesByUid.set(ov.uid, []);
            overridesByUid.get(ov.uid).push(ov);
        }

        const out = [];
        const today = new Date();
        const windowStart = new Date(today.getTime() - windowPastDays * 86400000);
        const windowEnd = new Date(today.getTime() + windowFutureDays * 86400000);

        for (const ev of masters) {
            const evOverrides = overridesByUid.get(ev.uid) || [];
            const excludedWallClocks = new Set([...ev.exdates, ...evOverrides.map(o => o.recurrenceId)]);

            if (!ev.rrule) {
                if (ev.dtstart && ev.dtstart.date >= windowStart && ev.dtstart.date <= windowEnd && !excludedWallClocks.has(ev.dtstart.wallClock))
                    out.push({ day: dayString(ev.dtstart.date), subject: ev.summary });
                continue;
            }

            for (const occ of expandRrule(ev, windowStart, windowEnd, excludedWallClocks))
                out.push({ day: dayString(occ), subject: ev.summary });
        }

        for (const ov of overrides) {
            if (ov.status === "CANCELLED")
                continue;
            if (!ov.dtstart || ov.dtstart.date < windowStart || ov.dtstart.date > windowEnd)
                continue;
            out.push({ day: dayString(ov.dtstart.date), subject: ov.summary });
        }

        return out;
    }
}
