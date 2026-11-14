// Offline checks of the voice picker's Worker side (src/voices.ts).
// Run with Node 23.6 or newer, which runs TypeScript directly:
//   node worker/test/voices.check.ts
// No network, no account and no keys: ElevenLabs is a fake `fetchUpstream`.

import {
  MAXIMUM_SPEECH_SPEED,
  MINIMUM_SPEECH_SPEED,
  VOICE_LIST_CACHE_MILLISECONDS,
  cleanedVoiceText,
  forgetCachedAccountVoiceList,
  handleVoicesRequest,
  loadAccountVoices,
  prepareTextToSpeechForwarding,
  voiceIdIsWellFormed,
  voicesForAppFromElevenLabsPage,
  type TextToSpeechForwarding,
  type UpstreamFetch,
  type VoicesEnvironment,
} from "../src/voices.ts";

let passedCheckCount = 0;
const failedCheckDescriptions: string[] = [];

function check(description: string, condition: boolean): void {
  if (condition) {
    passedCheckCount += 1;
  } else {
    failedCheckDescriptions.push(description);
  }
}

const fakeKey = "fake-elevenlabs-key-for-checks";
const defaultVoiceId = "DefaultVoice0001";
const environment: VoicesEnvironment = { ELEVENLABS_API_KEY: fakeKey, ELEVENLABS_VOICE_ID: defaultVoiceId };

function fakeVoice(voiceId: string, name: string, extraFields: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    voice_id: voiceId,
    name,
    category: "premade",
    labels: { accent: "american", gender: "female" },
    preview_url: "https://storage.example/preview.mp3",
    settings: { stability: 0.5 },
    samples: [{ sample_id: "s1" }],
    ...extraFields,
  };
}

/** A fake ElevenLabs that serves the given pages in order and records every request. */
function makeFakeElevenLabs(pages: Array<Record<string, unknown>>, failWithStatus?: number) {
  const requestedURLs: string[] = [];
  const requestedHeaders: Array<Record<string, string>> = [];
  const fetchUpstream: UpstreamFetch = async (upstreamURL, init) => {
    requestedURLs.push(upstreamURL);
    requestedHeaders.push((init?.headers ?? {}) as Record<string, string>);
    if (failWithStatus !== undefined) {
      return new Response(JSON.stringify({ detail: { status: "invalid_api_key" } }), { status: failWithStatus });
    }
    const pageIndex = Math.min(requestedURLs.length - 1, pages.length - 1);
    return new Response(JSON.stringify(pages[pageIndex]), { status: 200 });
  };
  return { fetchUpstream, requestedURLs, requestedHeaders };
}

// --- cleaning and the id rule ---

check("text becomes one line", cleanedVoiceText("Rachel\n  the\tvoice") === "Rachel the voice");
check("text is cut to 60 characters", cleanedVoiceText("x".repeat(80)).length === 60);
check("a normal id is well formed", voiceIdIsWellFormed("21m00Tcm4TlvDq8ikWAM"));
check("an id with a slash is refused", !voiceIdIsWellFormed("../admin"));
check("an id with a space is refused", !voiceIdIsWellFormed("a b"));
check("an empty id is refused", !voiceIdIsWellFormed(""));
check("an id of 65 characters is refused", !voiceIdIsWellFormed("a".repeat(65)));

// --- one page, as the app receives it ---

const pageVoices = voicesForAppFromElevenLabsPage({
  voices: [
    fakeVoice("VoiceA", "Rachel"),
    fakeVoice("VoiceB", "  Sam's\nclone ", { category: "cloned", labels: { accent: "dutch", age: 7, nested: { x: 1 } } }),
    fakeVoice("Bad/Id", "Slash"),
    { name: "No id" },
    { voice_id: "NoName" },
    "not an object",
    fakeVoice("VoiceC", "   "),
  ],
});
check("only voices with a good id and a name are kept", pageVoices.length === 2);
check("the first voice keeps its id and name", pageVoices[0]?.id === "VoiceA" && pageVoices[0]?.name === "Rachel");
check("a name is cleaned to one line", pageVoices[1]?.name === "Sam's clone");
check("the category comes through", pageVoices[1]?.category === "cloned");
check(
  "labels keep only string values",
  JSON.stringify(pageVoices[1]?.labels) === JSON.stringify({ accent: "dutch" })
);
const pageVoicesText = JSON.stringify(pageVoices);
check("no preview link reaches the app", !pageVoicesText.includes("preview"));
check("no settings or samples reach the app", !pageVoicesText.includes("stability") && !pageVoicesText.includes("sample"));
check("a page that is not an object gives no voices", voicesForAppFromElevenLabsPage("nope").length === 0);
check("a page without a list gives no voices", voicesForAppFromElevenLabsPage({ voices: 5 }).length === 0);

// --- loading the account's list ---

forgetCachedAccountVoiceList();
const twoPages = makeFakeElevenLabs([
  { voices: [fakeVoice("VoiceA", "Rachel")], has_more: true, next_page_token: "page-two" },
  { voices: [fakeVoice("VoiceB", "Clone")], has_more: false, next_page_token: null },
]);
const loadedTwoPages = await loadAccountVoices(environment, twoPages.fetchUpstream, 1_000);
check("two pages are both read", "voices" in loadedTwoPages && loadedTwoPages.voices.length === 2);
check("the second request carries the next page token", twoPages.requestedURLs[1]?.includes("next_page_token=page-two") === true);
check(
  "pages are asked for 100 at a time without a total count",
  twoPages.requestedURLs[0]?.includes("page_size=100") === true &&
    twoPages.requestedURLs[0]?.includes("include_total_count=false") === true &&
    twoPages.requestedURLs[0]?.startsWith("https://api.elevenlabs.io/v2/voices?") === true
);
check("the key goes in the xi-api-key header", twoPages.requestedHeaders[0]?.["xi-api-key"] === fakeKey);
await loadAccountVoices(environment, twoPages.fetchUpstream, 1_000 + VOICE_LIST_CACHE_MILLISECONDS - 1);
check("within 10 minutes the list is not fetched again", twoPages.requestedURLs.length === 2);
await loadAccountVoices(environment, twoPages.fetchUpstream, 1_000 + VOICE_LIST_CACHE_MILLISECONDS);
// The fake serves its last page from then on, so the fetch after 10 minutes is one more request.
check("after 10 minutes the list is fetched again", twoPages.requestedURLs.length === 3);

forgetCachedAccountVoiceList();
const endlessPages = makeFakeElevenLabs([{ voices: [fakeVoice("VoiceA", "Rachel")], has_more: true, next_page_token: "again" }]);
await loadAccountVoices(environment, endlessPages.fetchUpstream, 1_000);
check("paging stops after 5 pages", endlessPages.requestedURLs.length === 5);

forgetCachedAccountVoiceList();
const failingList = makeFakeElevenLabs([], 401);
const failedLoad = await loadAccountVoices(environment, failingList.fetchUpstream, 1_000);
check("an upstream failure comes back with its status", "failedStatus" in failedLoad && failedLoad.failedStatus === 401);
await loadAccountVoices(environment, failingList.fetchUpstream, 1_001);
check("a failure is not cached", failingList.requestedURLs.length === 2);

forgetCachedAccountVoiceList();
const throwingFetch: UpstreamFetch = async () => {
  throw new Error("network lost");
};
const unreachableLoad = await loadAccountVoices(environment, throwingFetch, 1_000);
check("an unreachable ElevenLabs is a 502", "failedStatus" in unreachableLoad && unreachableLoad.failedStatus === 502);

// --- POST /voices ---

forgetCachedAccountVoiceList();
const listForRoute = makeFakeElevenLabs([{ voices: [fakeVoice("VoiceA", "Rachel")], has_more: false }]);
const voicesResponse = await handleVoicesRequest(environment, listForRoute.fetchUpstream);
const voicesResponseText = await voicesResponse.text();
const voicesResponseJSON = JSON.parse(voicesResponseText) as { voices: unknown[]; defaultVoiceId: string };
check("the voices route answers 200", voicesResponse.status === 200);
check("the voices route lists the voices", voicesResponseJSON.voices.length === 1);
check("the voices route names the default voice", voicesResponseJSON.defaultVoiceId === defaultVoiceId);
check("the voices route never holds the key", !voicesResponseText.includes(fakeKey));
check("the voices route is JSON", voicesResponse.headers.get("content-type") === "application/json");

forgetCachedAccountVoiceList();
const failingRouteList = makeFakeElevenLabs([], 401);
const originalConsoleError = console.error;
console.error = () => {};
const failedVoicesResponse = await handleVoicesRequest(environment, failingRouteList.fetchUpstream);
console.error = originalConsoleError;
check("an upstream failure passes its status through", failedVoicesResponse.status === 401);
const missingKeyResponse = await handleVoicesRequest({ ELEVENLABS_API_KEY: "", ELEVENLABS_VOICE_ID: defaultVoiceId }, listForRoute.fetchUpstream);
check("without the key the voices route is a 500", missingKeyResponse.status === 500);

// --- POST /tts: the voice and the speed ---

async function forwardingFor(bodyObjectOrText: unknown, fetchUpstream: UpstreamFetch): Promise<TextToSpeechForwarding | Response> {
  const bodyText = typeof bodyObjectOrText === "string" ? bodyObjectOrText : JSON.stringify(bodyObjectOrText);
  return prepareTextToSpeechForwarding(bodyText, environment, fetchUpstream);
}

const todaysBodyText =
  '{"model_id":"eleven_flash_v2_5","text":"hello there","voice_settings":{"similarity_boost":0.75,"stability":0.5}}';
const noListNeeded = makeFakeElevenLabs([], 500);
const todaysForwarding = (await forwardingFor(todaysBodyText, noListNeeded.fetchUpstream)) as TextToSpeechForwarding;
check("today's body is forwarded byte for byte", todaysForwarding.bodyToForward === todaysBodyText);
check("today's body goes to the default voice", todaysForwarding.voiceIdForPath === defaultVoiceId);
check("today's body is no fallback", !todaysForwarding.usedDefaultVoiceAsFallback);
check("today's body never loads the list", noListNeeded.requestedURLs.length === 0);

forgetCachedAccountVoiceList();
const accountList = makeFakeElevenLabs([{ voices: [fakeVoice("VoiceA", "Rachel"), fakeVoice("VoiceB", "Clone")], has_more: false }]);
const chosenForwarding = (await forwardingFor(
  { text: "hi", model_id: "eleven_flash_v2_5", voice_settings: { stability: 0.5, similarity_boost: 0.75 }, voice_id: "VoiceB" },
  accountList.fetchUpstream
)) as TextToSpeechForwarding;
check("a listed voice is used", chosenForwarding.voiceIdForPath === "VoiceB" && !chosenForwarding.usedDefaultVoiceAsFallback);
const chosenBody = JSON.parse(chosenForwarding.bodyToForward) as Record<string, unknown>;
check("the voice id is taken out of the body", !("voice_id" in chosenBody));
check(
  "the other fields stay",
  chosenBody.text === "hi" &&
    chosenBody.model_id === "eleven_flash_v2_5" &&
    JSON.stringify(chosenBody.voice_settings) === JSON.stringify({ stability: 0.5, similarity_boost: 0.75 })
);

const unknownForwarding = (await forwardingFor({ text: "hi", voice_id: "GoneVoice" }, accountList.fetchUpstream)) as TextToSpeechForwarding;
check("a voice not in the account falls back to the default", unknownForwarding.voiceIdForPath === defaultVoiceId);
check("the fallback is reported", unknownForwarding.usedDefaultVoiceAsFallback);

for (const malformedVoiceId of ["../../v1/user", "a b", "x".repeat(65), 42, ""]) {
  const malformedForwarding = (await forwardingFor({ text: "hi", voice_id: malformedVoiceId }, accountList.fetchUpstream)) as TextToSpeechForwarding;
  check(
    `a malformed voice id (${String(malformedVoiceId).slice(0, 12)}) never reaches the path`,
    malformedForwarding.voiceIdForPath === defaultVoiceId && malformedForwarding.usedDefaultVoiceAsFallback
  );
}

const nullForwarding = (await forwardingFor({ text: "hi", voice_id: null }, accountList.fetchUpstream)) as TextToSpeechForwarding;
check(
  "a null voice id means the default, with no fallback",
  nullForwarding.voiceIdForPath === defaultVoiceId &&
    !nullForwarding.usedDefaultVoiceAsFallback &&
    !("voice_id" in (JSON.parse(nullForwarding.bodyToForward) as Record<string, unknown>))
);

forgetCachedAccountVoiceList();
const defaultChoiceList = makeFakeElevenLabs([], 500);
const defaultChoiceForwarding = (await forwardingFor({ text: "hi", voice_id: defaultVoiceId }, defaultChoiceList.fetchUpstream)) as TextToSpeechForwarding;
check("choosing the default voice needs no list", defaultChoiceForwarding.voiceIdForPath === defaultVoiceId && defaultChoiceList.requestedURLs.length === 0);

forgetCachedAccountVoiceList();
const outage = makeFakeElevenLabs([], 503);
const outageForwarding = (await forwardingFor({ text: "hi", voice_id: "VoiceB" }, outage.fetchUpstream)) as TextToSpeechForwarding;
check(
  "when the list cannot be loaded the chosen voice is used and no fallback is reported",
  outageForwarding.voiceIdForPath === "VoiceB" && !outageForwarding.usedDefaultVoiceAsFallback
);

async function speedAfterForwarding(requestedSpeed: unknown): Promise<unknown> {
  const speedForwarding = (await forwardingFor({ text: "hi", voice_settings: { stability: 0.5, speed: requestedSpeed } }, noListNeeded.fetchUpstream)) as TextToSpeechForwarding;
  return (JSON.parse(speedForwarding.bodyToForward) as { voice_settings: Record<string, unknown> }).voice_settings.speed;
}
check("a speed in range stays", (await speedAfterForwarding(1.1)) === 1.1);
check("a speed of 5 becomes the fastest", (await speedAfterForwarding(5)) === MAXIMUM_SPEECH_SPEED);
check("a speed of 0.1 becomes the slowest", (await speedAfterForwarding(0.1)) === MINIMUM_SPEECH_SPEED);
check("a speed that is not a number is removed", (await speedAfterForwarding("fast")) === undefined);
check("a null speed is removed", (await speedAfterForwarding(null)) === undefined);
check("a speed alone keeps the default voice", ((await forwardingFor({ text: "hi", voice_settings: { speed: 1.1 } }, noListNeeded.fetchUpstream)) as TextToSpeechForwarding).voiceIdForPath === defaultVoiceId);

for (const badBodyText of ["[]", "null", "nope", '"text"', "42"]) {
  const badBodyResponse = await forwardingFor(badBodyText, noListNeeded.fetchUpstream);
  const badBodyAnswer = badBodyResponse instanceof Response ? await badBodyResponse.text() : "";
  check(
    `a body that is not a JSON object (${badBodyText}) is a 400`,
    badBodyResponse instanceof Response &&
      badBodyResponse.status === 400 &&
      badBodyAnswer === '{"error":{"type":"bad_request","message":"body must be a json object"}}'
  );
}

if (failedCheckDescriptions.length > 0) {
  console.log(`voice checks: ${passedCheckCount} passed, ${failedCheckDescriptions.length} FAILED`);
  for (const failedCheckDescription of failedCheckDescriptions) {
    console.log(`  FAILED: ${failedCheckDescription}`);
  }
  process.exit(1);
}
console.log(`voice checks: ${passedCheckCount} passed, 0 failed`);
