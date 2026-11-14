// Offline checks of the daily spending cap (src/dailyCap.ts).
// Run with Node 23.6 or newer, which runs TypeScript directly:
//   node worker/test/dailyCap.check.ts
// No network, no Cloudflare account and no keys are needed: the counter
// object runs against an in-memory stand-in for Durable Object storage.

import {
  ClickyDailyCap,
  DEFAULT_DAILY_CHAT_REQUEST_CAP,
  DEFAULT_DAILY_TTS_CHARACTER_CAP,
  dailyCapAllowsRequest,
  dailyCapReachedResponse,
  dailyLimitFromSetting,
  decideDailyCapRequest,
  textToSpeechCharacterCount,
  utcDayOf,
  type DailyCapCounterNamespace,
  type DailyCapEnvironment,
} from "../src/dailyCap.ts";

let passedCheckCount = 0;
const failedCheckDescriptions: string[] = [];

function check(description: string, condition: boolean): void {
  if (condition) {
    passedCheckCount += 1;
  } else {
    failedCheckDescriptions.push(description);
  }
}

// --- the pure decision ---

const today = "2026-11-14";
const yesterday = "2026-11-13";

check("a first request of the day is allowed", decideDailyCapRequest(undefined, today, "chatRequests", 1, 600).isAllowed);
check(
  "the first request of the day counts 1",
  decideDailyCapRequest(undefined, today, "chatRequests", 1, 600).countersAfterRequest.chatRequests === 1
);
check(
  "the 600th chat request is allowed",
  decideDailyCapRequest({ utcDay: today, chatRequests: 599, textToSpeechCharacters: 0 }, today, "chatRequests", 1, 600)
    .isAllowed
);
check(
  "the 601st chat request is refused",
  !decideDailyCapRequest({ utcDay: today, chatRequests: 600, textToSpeechCharacters: 0 }, today, "chatRequests", 1, 600)
    .isAllowed
);
check(
  "a refused request leaves the counters as they were",
  decideDailyCapRequest({ utcDay: today, chatRequests: 600, textToSpeechCharacters: 5 }, today, "chatRequests", 1, 600)
    .countersAfterRequest.chatRequests === 600
);
check(
  "yesterday's counters count as zero today",
  decideDailyCapRequest({ utcDay: yesterday, chatRequests: 600, textToSpeechCharacters: 60_000 }, today, "chatRequests", 1, 600)
    .isAllowed
);
const firstRequestAfterMidnight = decideDailyCapRequest(
  { utcDay: yesterday, chatRequests: 600, textToSpeechCharacters: 60_000 },
  today,
  "textToSpeechCharacters",
  40,
  60_000
);
check(
  "a new day starts both counters from zero",
  firstRequestAfterMidnight.countersAfterRequest.utcDay === today &&
    firstRequestAfterMidnight.countersAfterRequest.chatRequests === 0 &&
    firstRequestAfterMidnight.countersAfterRequest.textToSpeechCharacters === 40
);
check(
  "speech that would pass the character cap is refused",
  !decideDailyCapRequest({ utcDay: today, chatRequests: 0, textToSpeechCharacters: 59_990 }, today, "textToSpeechCharacters", 11, 60_000)
    .isAllowed
);
check(
  "speech that lands exactly on the character cap is allowed",
  decideDailyCapRequest({ utcDay: today, chatRequests: 0, textToSpeechCharacters: 59_990 }, today, "textToSpeechCharacters", 10, 60_000)
    .isAllowed
);
check(
  "the chat counter does not use up the speech counter",
  decideDailyCapRequest({ utcDay: today, chatRequests: 600, textToSpeechCharacters: 0 }, today, "textToSpeechCharacters", 50, 60_000)
    .isAllowed
);
check("a cap of zero refuses everything", !decideDailyCapRequest(undefined, today, "chatRequests", 1, 0).isAllowed);
const storedBeforeDecision = { utcDay: today, chatRequests: 3, textToSpeechCharacters: 0 };
decideDailyCapRequest(storedBeforeDecision, today, "chatRequests", 1, 600);
check("the decision does not change the stored counters it was given", storedBeforeDecision.chatRequests === 3);

// --- settings, character counts, the day ---

check("no setting gives the default", dailyLimitFromSetting(undefined, 600) === 600);
check("an empty setting gives the default", dailyLimitFromSetting("  ", 600) === 600);
check("a number setting is used", dailyLimitFromSetting("2", 600) === 2);
check("a zero setting is used", dailyLimitFromSetting("0", 600) === 0);
check("a negative setting gives the default", dailyLimitFromSetting("-5", 600) === 600);
check("a fractional setting gives the default", dailyLimitFromSetting("2.5", 600) === 600);
check("a word setting gives the default", dailyLimitFromSetting("lots", 600) === 600);
check("the defaults are Sam's numbers", DEFAULT_DAILY_CHAT_REQUEST_CAP === 600 && DEFAULT_DAILY_TTS_CHARACTER_CAP === 60_000);

check("the speech count is the text's length", textToSpeechCharacterCount(JSON.stringify({ text: "hello there", model_id: "x" })) === 11);
check("a body that is not JSON counts zero", textToSpeechCharacterCount("not json") === 0);
check("a body without text counts zero", textToSpeechCharacterCount(JSON.stringify({ model_id: "x" })) === 0);
check("a text that is not a string counts zero", textToSpeechCharacterCount(JSON.stringify({ text: 42 })) === 0);
check("a JSON null body counts zero", textToSpeechCharacterCount("null") === 0);

check("the day is the UTC day", utcDayOf(new Date("2026-11-14T23:59:59.000Z")) === "2026-11-14");
check("midnight UTC starts the next day", utcDayOf(new Date("2026-11-15T00:00:00.000Z")) === "2026-11-15");
check("the day does not follow Amsterdam time", utcDayOf(new Date("2026-11-15T00:30:00+01:00")) === "2026-11-14");

// --- the 429 answer ---

const capReachedResponse = dailyCapReachedResponse();
const capReachedBody = await capReachedResponse.text();
check("the cap answer is HTTP 429", capReachedResponse.status === 429);
check(
  "the cap answer has the exact body the app looks for",
  capReachedBody === '{"error":{"type":"clicky_daily_cap","message":"daily cap reached"}}'
);
check("the cap answer has the header (read case-insensitively)", capReachedResponse.headers.get("x-clicky-cap") === "daily");
check("the cap answer is JSON", capReachedResponse.headers.get("content-type") === "application/json");

// --- the counter object and the Worker side, end to end in memory ---

class InMemoryDurableObjectStorage {
  readonly valuesByKey = new Map<string, unknown>();
  putCount = 0;
  async get(key: string): Promise<unknown> {
    // A structured copy, like real storage, so the caller cannot change what is stored.
    const storedValue = this.valuesByKey.get(key);
    return storedValue === undefined ? undefined : structuredClone(storedValue);
  }
  async put(key: string, value: unknown): Promise<void> {
    this.putCount += 1;
    this.valuesByKey.set(key, structuredClone(value));
  }
}

function makeCounterNamespace(counterObject: ClickyDailyCap): DailyCapCounterNamespace & { requestedObjectNames: string[] } {
  const requestedObjectNames: string[] = [];
  return {
    requestedObjectNames,
    idFromName(name: string): unknown {
      requestedObjectNames.push(name);
      return { name };
    },
    get(): { fetch(url: string, init?: RequestInit): Promise<Response> } {
      return {
        fetch: (url: string, init?: RequestInit) => counterObject.fetch(new Request(url, init)),
      };
    },
  };
}

const counterStorage = new InMemoryDurableObjectStorage();
const counterObject = new ClickyDailyCap({ storage: counterStorage });
const counterNamespace = makeCounterNamespace(counterObject);
const lowCapEnvironment: DailyCapEnvironment = {
  CLICKY_DAILY_CAP: counterNamespace,
  CLICKY_DAILY_CHAT_REQUEST_CAP: "2",
  CLICKY_DAILY_TTS_CHARACTER_CAP: "20",
};

check("chat request 1 of 2 goes through", await dailyCapAllowsRequest(lowCapEnvironment, "chatRequests", 1));
check("chat request 2 of 2 goes through", await dailyCapAllowsRequest(lowCapEnvironment, "chatRequests", 1));
check("chat request 3 is refused", !(await dailyCapAllowsRequest(lowCapEnvironment, "chatRequests", 1)));
check("chat request 4 is refused too", !(await dailyCapAllowsRequest(lowCapEnvironment, "chatRequests", 1)));
check("speech of 15 characters goes through", await dailyCapAllowsRequest(lowCapEnvironment, "textToSpeechCharacters", 15));
check("speech of 10 more characters is refused", !(await dailyCapAllowsRequest(lowCapEnvironment, "textToSpeechCharacters", 10)));
check("speech of 5 more characters goes through", await dailyCapAllowsRequest(lowCapEnvironment, "textToSpeechCharacters", 5));
check("speech of 1 more character is refused", !(await dailyCapAllowsRequest(lowCapEnvironment, "textToSpeechCharacters", 1)));
check("empty speech still goes through at the cap", await dailyCapAllowsRequest(lowCapEnvironment, "textToSpeechCharacters", 0));
const storedCounters = counterStorage.valuesByKey.get("dailyCounters") as {
  utcDay: string;
  chatRequests: number;
  textToSpeechCharacters: number;
};
check(
  "the stored counters hold exactly what was allowed",
  storedCounters.chatRequests === 2 && storedCounters.textToSpeechCharacters === 20 && storedCounters.utcDay === utcDayOf(new Date())
);
check("a refused request writes nothing", counterStorage.putCount === 5);
check(
  "every request talks to the one counter object",
  counterNamespace.requestedObjectNames.every((objectName) => objectName === "clicky-daily-cap")
);

const defaultLimitEnvironment: DailyCapEnvironment = { CLICKY_DAILY_CAP: counterNamespace };
check(
  "with no setting the default cap of 600 applies (2 used, so more go through)",
  await dailyCapAllowsRequest(defaultLimitEnvironment, "chatRequests", 1)
);

// Yesterday's counters in storage: today starts from zero.
const rolloverStorage = new InMemoryDurableObjectStorage();
rolloverStorage.valuesByKey.set("dailyCounters", { utcDay: "2000-01-01", chatRequests: 2, textToSpeechCharacters: 20 });
const rolloverEnvironment: DailyCapEnvironment = {
  CLICKY_DAILY_CAP: makeCounterNamespace(new ClickyDailyCap({ storage: rolloverStorage })),
  CLICKY_DAILY_CHAT_REQUEST_CAP: "2",
};
check("an old day in storage does not block today", await dailyCapAllowsRequest(rolloverEnvironment, "chatRequests", 1));

// A stored value of the wrong shape counts as nothing stored.
const damagedStorage = new InMemoryDurableObjectStorage();
damagedStorage.valuesByKey.set("dailyCounters", { utcDay: 5, chatRequests: "lots" });
const damagedEnvironment: DailyCapEnvironment = {
  CLICKY_DAILY_CAP: makeCounterNamespace(new ClickyDailyCap({ storage: damagedStorage })),
  CLICKY_DAILY_CHAT_REQUEST_CAP: "2",
};
check("a damaged stored value does not block requests", await dailyCapAllowsRequest(damagedEnvironment, "chatRequests", 1));

// The counter object refuses a malformed count request with HTTP 400.
const malformedCountResponse = await counterObject.fetch(
  new Request("https://clicky-daily-cap/count", { method: "POST", body: JSON.stringify({ counterName: "dollars", amount: 1, limit: 2 }) })
);
check("the counter refuses an unknown counter name", malformedCountResponse.status === 400);
const notJSONCountResponse = await counterObject.fetch(new Request("https://clicky-daily-cap/count", { method: "POST", body: "{" }));
check("the counter refuses a body that is not JSON", notJSONCountResponse.status === 400);

// --- failing open ---

const originalConsoleError = console.error;
const loggedErrors: string[] = [];
console.error = (...parts: unknown[]) => {
  loggedErrors.push(parts.map(String).join(" "));
};
try {
  check("without the binding the cap is off", await dailyCapAllowsRequest({}, "chatRequests", 1));
  const throwingNamespace: DailyCapCounterNamespace = {
    idFromName: () => ({}),
    get: () => ({
      fetch: async () => {
        throw new Error("network lost");
      },
    }),
  };
  check(
    "a counter that cannot be reached lets the request through",
    await dailyCapAllowsRequest({ CLICKY_DAILY_CAP: throwingNamespace, CLICKY_DAILY_CHAT_REQUEST_CAP: "0" }, "chatRequests", 1)
  );
  const erroringNamespace: DailyCapCounterNamespace = {
    idFromName: () => ({}),
    get: () => ({ fetch: async () => new Response("overloaded", { status: 503 }) }),
  };
  check(
    "a counter that answers an error lets the request through",
    await dailyCapAllowsRequest({ CLICKY_DAILY_CAP: erroringNamespace, CLICKY_DAILY_CHAT_REQUEST_CAP: "0" }, "chatRequests", 1)
  );
  check("both failures were logged", loggedErrors.length === 2 && loggedErrors.every((line) => line.startsWith("[daily cap]")));
} finally {
  console.error = originalConsoleError;
}

if (failedCheckDescriptions.length > 0) {
  console.log(`daily cap checks: ${passedCheckCount} passed, ${failedCheckDescriptions.length} FAILED`);
  for (const failedCheckDescription of failedCheckDescriptions) {
    console.log(`  FAILED: ${failedCheckDescription}`);
  }
  process.exit(1);
}
console.log(`daily cap checks: ${passedCheckCount} passed, 0 failed`);
