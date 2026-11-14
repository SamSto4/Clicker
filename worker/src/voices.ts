/**
 * The voice picker's Worker side (round 20, "look and sound").
 *
 * `POST /voices` lists the ElevenLabs account's voices for the app's picker,
 * and `POST /tts` accepts two optional fields: `voice_id` (the chosen voice)
 * and `voice_settings.speed`. With neither, a `/tts` body is forwarded byte
 * for byte as before, to the Worker's default voice (`ELEVENLABS_VOICE_ID`).
 *
 * The app never talks to ElevenLabs itself, so this is the only place that
 * holds the key. Only a voice's id, name, category and labels reach the app:
 * never the key, never preview links, samples or settings.
 *
 * This module has no imports, so `test/voices.check.ts` can run it with Node
 * alone. Upstream requests go through a `fetchUpstream` function that the
 * Worker passes as the real `fetch` and the checks pass as a fake.
 */

export interface VoicesEnvironment {
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
}

/** A voice as the app receives it. */
export interface VoiceForApp {
  id: string;
  name: string;
  category?: string;
  labels?: Record<string, string>;
}

/** What text to speech is sent to ElevenLabs after the optional fields are handled. */
export interface TextToSpeechForwarding {
  voiceIdForPath: string;
  bodyToForward: string;
  /** True when a chosen voice could not be used and the default spoke instead. */
  usedDefaultVoiceAsFallback: boolean;
}

export type UpstreamFetch = (url: string, init?: RequestInit) => Promise<Response>;

/** The account's list is fetched at most this often per Worker instance. */
export const VOICE_LIST_CACHE_MILLISECONDS = 10 * 60 * 1000;
/** ElevenLabs lists at most 100 voices a page; 5 pages are 500 voices, far more than an account has. */
export const MAXIMUM_VOICE_LIST_PAGES = 5;
/** Names and labels are the account's own text; they reach the app cut to this length. */
export const MAXIMUM_VOICE_TEXT_CHARACTERS = 60;
/**
 * The speed range ElevenLabs' settings slider offers. The API reference gives
 * `voice_settings.speed` (default 1.0) without a range, so a value outside
 * this one is pulled to its nearest end rather than sent as it came.
 */
export const MINIMUM_SPEECH_SPEED = 0.7;
export const MAXIMUM_SPEECH_SPEED = 1.2;

/** A voice id goes into the upstream URL path, so only these characters are ever accepted. */
const VOICE_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

const ELEVENLABS_VOICE_LIST_URL = "https://api.elevenlabs.io/v2/voices";

/** This instance's copy of the account's list (an isolate restart simply fetches it again). */
let cachedAccountVoiceList: { fetchedAtMilliseconds: number; voices: VoiceForApp[] } | undefined;

/** Empties this instance's copy of the list; the offline checks call it between cases. */
export function forgetCachedAccountVoiceList(): void {
  cachedAccountVoiceList = undefined;
}

export function voiceIdIsWellFormed(voiceId: string): boolean {
  return VOICE_ID_PATTERN.test(voiceId);
}

/** One line (every run of whitespace becomes one space), trimmed, cut to 60 characters. */
export function cleanedVoiceText(text: string): string {
  return text.replace(/\s+/g, " ").trim().slice(0, MAXIMUM_VOICE_TEXT_CHARACTERS);
}

/**
 * The voices of one ElevenLabs list page, as the app receives them. Tolerant:
 * a voice without a string id and name is skipped, and labels keep only string values.
 */
export function voicesForAppFromElevenLabsPage(pageJSON: unknown): VoiceForApp[] {
  if (typeof pageJSON !== "object" || pageJSON === null) {
    return [];
  }
  const listedVoices = (pageJSON as { voices?: unknown }).voices;
  if (!Array.isArray(listedVoices)) {
    return [];
  }
  const voicesForApp: VoiceForApp[] = [];
  for (const listedVoice of listedVoices) {
    if (typeof listedVoice !== "object" || listedVoice === null) {
      continue;
    }
    const { voice_id: voiceId, name, category, labels } = listedVoice as {
      voice_id?: unknown;
      name?: unknown;
      category?: unknown;
      labels?: unknown;
    };
    if (typeof voiceId !== "string" || !voiceIdIsWellFormed(voiceId) || typeof name !== "string") {
      continue;
    }
    const cleanedName = cleanedVoiceText(name);
    if (cleanedName === "") {
      continue;
    }
    const voiceForApp: VoiceForApp = { id: voiceId, name: cleanedName };
    if (typeof category === "string" && cleanedVoiceText(category) !== "") {
      voiceForApp.category = cleanedVoiceText(category);
    }
    if (typeof labels === "object" && labels !== null && !Array.isArray(labels)) {
      const stringLabels: Record<string, string> = {};
      for (const [labelName, labelValue] of Object.entries(labels as Record<string, unknown>)) {
        if (typeof labelValue === "string" && cleanedVoiceText(labelValue) !== "") {
          stringLabels[cleanedVoiceText(labelName)] = cleanedVoiceText(labelValue);
        }
      }
      if (Object.keys(stringLabels).length > 0) {
        voiceForApp.labels = stringLabels;
      }
    }
    voicesForApp.push(voiceForApp);
  }
  return voicesForApp;
}

/**
 * The account's voices, from this instance's copy when it is under 10 minutes
 * old, else fetched page by page. A failure comes back as the upstream status
 * and body (or a 502 when ElevenLabs could not be reached) and is not cached.
 */
export async function loadAccountVoices(
  env: VoicesEnvironment,
  fetchUpstream: UpstreamFetch,
  nowMilliseconds: number = Date.now()
): Promise<{ voices: VoiceForApp[] } | { failedStatus: number; failedBodyText: string }> {
  if (
    cachedAccountVoiceList !== undefined &&
    nowMilliseconds - cachedAccountVoiceList.fetchedAtMilliseconds < VOICE_LIST_CACHE_MILLISECONDS
  ) {
    return { voices: cachedAccountVoiceList.voices };
  }

  const accountVoices: VoiceForApp[] = [];
  let nextPageToken: string | undefined;
  try {
    for (let pageNumber = 1; pageNumber <= MAXIMUM_VOICE_LIST_PAGES; pageNumber++) {
      const pageURL = new URL(ELEVENLABS_VOICE_LIST_URL);
      pageURL.searchParams.set("page_size", "100");
      pageURL.searchParams.set("include_total_count", "false");
      if (nextPageToken !== undefined) {
        pageURL.searchParams.set("next_page_token", nextPageToken);
      }
      const pageResponse = await fetchUpstream(pageURL.toString(), {
        method: "GET",
        headers: { "xi-api-key": env.ELEVENLABS_API_KEY, accept: "application/json" },
      });
      if (!pageResponse.ok) {
        return { failedStatus: pageResponse.status, failedBodyText: await pageResponse.text() };
      }
      const pageJSON = (await pageResponse.json()) as { has_more?: unknown; next_page_token?: unknown };
      accountVoices.push(...voicesForAppFromElevenLabsPage(pageJSON));
      if (pageJSON.has_more === true && typeof pageJSON.next_page_token === "string" && pageJSON.next_page_token !== "") {
        nextPageToken = pageJSON.next_page_token;
      } else {
        break;
      }
    }
  } catch (error) {
    return {
      failedStatus: 502,
      failedBodyText: JSON.stringify({ error: { type: "upstream_unreachable", message: String(error) } }),
    };
  }

  cachedAccountVoiceList = { fetchedAtMilliseconds: nowMilliseconds, voices: accountVoices };
  return { voices: accountVoices };
}

function jsonResponse(responseObject: unknown, status: number): Response {
  return new Response(JSON.stringify(responseObject), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** `POST /voices`: `{ voices: [{ id, name, category?, labels? }], defaultVoiceId }`. */
export async function handleVoicesRequest(env: VoicesEnvironment, fetchUpstream: UpstreamFetch): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY) {
    return jsonResponse({ error: { type: "not_configured", message: "the elevenlabs key is not set" } }, 500);
  }
  const loadedVoices = await loadAccountVoices(env, fetchUpstream);
  if ("failedStatus" in loadedVoices) {
    console.error(`[/voices] ElevenLabs voice list error ${loadedVoices.failedStatus}`);
    return new Response(loadedVoices.failedBodyText, {
      status: loadedVoices.failedStatus,
      headers: { "content-type": "application/json" },
    });
  }
  return jsonResponse({ voices: loadedVoices.voices, defaultVoiceId: env.ELEVENLABS_VOICE_ID }, 200);
}

/**
 * Decides the voice and the body of one `/tts` request.
 *
 * - A body without `voice_id` and without `voice_settings.speed` is forwarded
 *   exactly as it came, to the default voice.
 * - `voice_id` is taken out of the body (the voice belongs in the URL path).
 *   A well-formed id that is the default, or is in the account's list, is used.
 *   A malformed id, or one the list does not hold, falls back to the default
 *   and says so (`usedDefaultVoiceAsFallback`, which becomes the
 *   `X-Clicky-Voice-Fallback: 1` header). When the list cannot be loaded, the
 *   requested id is used as it came, so a passing ElevenLabs outage never
 *   makes the app drop the user's choice. A `voice_id` of null means the default.
 * - `voice_settings.speed` is pulled into 0.7...1.2, and removed when it is not a number.
 * - A body that is not a JSON object gets a 400.
 */
export async function prepareTextToSpeechForwarding(
  requestBodyText: string,
  env: VoicesEnvironment,
  fetchUpstream: UpstreamFetch
): Promise<TextToSpeechForwarding | Response> {
  let parsedBody: unknown;
  try {
    parsedBody = JSON.parse(requestBodyText);
  } catch {
    parsedBody = undefined;
  }
  if (typeof parsedBody !== "object" || parsedBody === null || Array.isArray(parsedBody)) {
    return jsonResponse({ error: { type: "bad_request", message: "body must be a json object" } }, 400);
  }

  const bodyObject = parsedBody as Record<string, unknown>;
  const voiceSettings = bodyObject.voice_settings;
  const voiceSettingsObject =
    typeof voiceSettings === "object" && voiceSettings !== null && !Array.isArray(voiceSettings)
      ? (voiceSettings as Record<string, unknown>)
      : undefined;
  const bodyHasVoiceId = Object.prototype.hasOwnProperty.call(bodyObject, "voice_id");
  const bodyHasSpeed =
    voiceSettingsObject !== undefined && Object.prototype.hasOwnProperty.call(voiceSettingsObject, "speed");

  if (!bodyHasVoiceId && !bodyHasSpeed) {
    return { voiceIdForPath: env.ELEVENLABS_VOICE_ID, bodyToForward: requestBodyText, usedDefaultVoiceAsFallback: false };
  }

  let voiceIdForPath = env.ELEVENLABS_VOICE_ID;
  let usedDefaultVoiceAsFallback = false;
  if (bodyHasVoiceId) {
    const requestedVoiceId = bodyObject.voice_id;
    delete bodyObject.voice_id;
    if (requestedVoiceId === null || requestedVoiceId === undefined) {
      // No voice chosen: the default, said plainly.
    } else if (typeof requestedVoiceId !== "string" || !voiceIdIsWellFormed(requestedVoiceId)) {
      usedDefaultVoiceAsFallback = true;
    } else if (requestedVoiceId === env.ELEVENLABS_VOICE_ID) {
      voiceIdForPath = requestedVoiceId;
    } else {
      const loadedVoices = await loadAccountVoices(env, fetchUpstream);
      if ("failedStatus" in loadedVoices) {
        voiceIdForPath = requestedVoiceId;
      } else if (loadedVoices.voices.some((voice) => voice.id === requestedVoiceId)) {
        voiceIdForPath = requestedVoiceId;
      } else {
        usedDefaultVoiceAsFallback = true;
      }
    }
  }

  if (bodyHasSpeed && voiceSettingsObject !== undefined) {
    const requestedSpeed = voiceSettingsObject.speed;
    if (typeof requestedSpeed === "number" && Number.isFinite(requestedSpeed)) {
      voiceSettingsObject.speed = Math.min(MAXIMUM_SPEECH_SPEED, Math.max(MINIMUM_SPEECH_SPEED, requestedSpeed));
    } else {
      delete voiceSettingsObject.speed;
    }
  }

  return { voiceIdForPath, bodyToForward: JSON.stringify(bodyObject), usedDefaultVoiceAsFallback };
}
