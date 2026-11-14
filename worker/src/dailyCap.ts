/**
 * Daily spending cap (Sam's decision, 14 Nov 2026): at most 600 `/chat`
 * requests and 60,000 text-to-speech characters per UTC day. Every `/chat`
 * request counts: each step of a tool loop, the dictation cleanup and the
 * memory compaction too, so 600 requests are fewer than 600 questions. A
 * request past the cap gets HTTP 429 with a fixed body and header, which the
 * app turns into "i've hit today's spending cap." The counts start again at
 * 00:00 UTC.
 *
 * The counts live in one Durable Object with SQLite storage. Workers KV was
 * the first idea, but its free plan allows 1,000 writes a day, which the
 * counting alone would use up. The free plan gives a Durable Object 100,000
 * requests and 100,000 rows written a day, and one object handles one request
 * at a time, so two requests can never both take the last place.
 *
 * This module is plain TypeScript with no imports, so `test/dailyCap.check.ts`
 * can run it with Node alone.
 */

export const DEFAULT_DAILY_CHAT_REQUEST_CAP = 600;
export const DEFAULT_DAILY_TTS_CHARACTER_CAP = 60_000;

/** The one counter object every request talks to. */
const DAILY_CAP_OBJECT_NAME = "clicky-daily-cap";

/** The single storage key: today's counters, replaced when the day changes. */
const DAILY_COUNTERS_STORAGE_KEY = "dailyCounters";

export type DailyCapCounterName = "chatRequests" | "textToSpeechCharacters";

export interface DailyCapCounters {
  utcDay: string;
  chatRequests: number;
  textToSpeechCharacters: number;
}

export interface DailyCapDecision {
  isAllowed: boolean;
  /** What to store when the request is allowed (unchanged when it is not). */
  countersAfterRequest: DailyCapCounters;
}

/**
 * The bindings and settings the cap reads. Everything is optional: without
 * the Durable Object binding the cap is off, and without a setting the
 * default limit applies. The settings are plain text vars, so the cap can be
 * tried at a low value with `wrangler dev --var CLICKY_DAILY_CHAT_REQUEST_CAP:2`.
 */
export interface DailyCapEnvironment {
  CLICKY_DAILY_CAP?: DailyCapCounterNamespace;
  CLICKY_DAILY_CHAT_REQUEST_CAP?: string;
  CLICKY_DAILY_TTS_CHARACTER_CAP?: string;
}

/** The part of a Durable Object namespace binding the cap uses. */
export interface DailyCapCounterNamespace {
  idFromName(name: string): unknown;
  get(objectId: unknown): { fetch(url: string, init?: RequestInit): Promise<Response> };
}

/** The part of the Durable Object's state the counter object uses. */
export interface DailyCapObjectState {
  storage: {
    get(key: string): Promise<unknown>;
    put(key: string, value: unknown): Promise<void>;
  };
}

/** The UTC calendar day of a moment, such as "2026-11-14". */
export function utcDayOf(moment: Date): string {
  return moment.toISOString().slice(0, 10);
}

/**
 * Today's counters after one request, and whether the request may go
 * through. A request is allowed when what was used today plus its own amount
 * stays within the limit, so with a limit of 600 the 600th chat request is
 * the last one allowed. Counters stored for another day count as zero.
 */
export function decideDailyCapRequest(
  storedCounters: DailyCapCounters | undefined,
  todayUtcDay: string,
  counterName: DailyCapCounterName,
  requestAmount: number,
  dailyLimit: number
): DailyCapDecision {
  const todaysCounters: DailyCapCounters =
    storedCounters !== undefined && storedCounters.utcDay === todayUtcDay
      ? { ...storedCounters }
      : { utcDay: todayUtcDay, chatRequests: 0, textToSpeechCharacters: 0 };

  const amountUsedToday = todaysCounters[counterName];
  if (amountUsedToday + requestAmount > dailyLimit) {
    return { isAllowed: false, countersAfterRequest: todaysCounters };
  }

  todaysCounters[counterName] = amountUsedToday + requestAmount;
  return { isAllowed: true, countersAfterRequest: todaysCounters };
}

/**
 * The limit from a plain text setting, or the default when the setting is
 * missing, empty, or not a whole number of zero or more.
 */
export function dailyLimitFromSetting(settingValue: string | undefined, defaultLimit: number): number {
  if (settingValue === undefined || settingValue.trim() === "") {
    return defaultLimit;
  }
  const parsedLimit = Number(settingValue);
  return Number.isInteger(parsedLimit) && parsedLimit >= 0 ? parsedLimit : defaultLimit;
}

/**
 * How many characters a `/tts` request asks to speak: the length of the
 * body's `text`. A body that is not JSON or has no text counts zero, because
 * ElevenLabs refuses such a request anyway.
 */
export function textToSpeechCharacterCount(requestBodyText: string): number {
  try {
    const parsedRequestBody = JSON.parse(requestBodyText) as { text?: unknown } | null;
    const textToSpeak = parsedRequestBody?.text;
    return typeof textToSpeak === "string" ? textToSpeak.length : 0;
  } catch {
    return 0;
  }
}

/** The fixed answer to a request past the cap; the app recognises the body type and the header. */
export function dailyCapReachedResponse(): Response {
  return new Response(
    JSON.stringify({ error: { type: "clicky_daily_cap", message: "daily cap reached" } }),
    {
      status: 429,
      headers: { "content-type": "application/json", "X-Clicky-Cap": "daily" },
    }
  );
}

/**
 * Counts one request against today's cap and says whether it may go through.
 * A refused request is not counted.
 *
 * Fails open: when the binding is missing or the counter cannot be reached,
 * the request goes through and the error is logged. The cap is a safety net
 * against runaway loops, and a broken counter must not take Clicky down; a
 * monthly limit in the Anthropic Console is the backstop.
 */
export async function dailyCapAllowsRequest(
  env: DailyCapEnvironment,
  counterName: DailyCapCounterName,
  requestAmount: number
): Promise<boolean> {
  const counterNamespace = env.CLICKY_DAILY_CAP;
  if (counterNamespace === undefined) {
    return true;
  }

  const dailyLimit =
    counterName === "chatRequests"
      ? dailyLimitFromSetting(env.CLICKY_DAILY_CHAT_REQUEST_CAP, DEFAULT_DAILY_CHAT_REQUEST_CAP)
      : dailyLimitFromSetting(env.CLICKY_DAILY_TTS_CHARACTER_CAP, DEFAULT_DAILY_TTS_CHARACTER_CAP);

  try {
    const counterObject = counterNamespace.get(counterNamespace.idFromName(DAILY_CAP_OBJECT_NAME));
    const counterResponse = await counterObject.fetch("https://clicky-daily-cap/count", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ counterName, amount: requestAmount, limit: dailyLimit }),
    });
    if (!counterResponse.ok) {
      throw new Error(`the counter answered HTTP ${counterResponse.status}`);
    }
    const counterResult = (await counterResponse.json()) as { allowed?: unknown };
    return counterResult.allowed !== false;
  } catch (error) {
    console.error("[daily cap] counter unavailable, request let through:", String(error));
    return true;
  }
}

function isWholeNumberOfZeroOrMore(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function storedCountersOrUndefined(storedValue: unknown): DailyCapCounters | undefined {
  if (typeof storedValue !== "object" || storedValue === null) {
    return undefined;
  }
  const candidateCounters = storedValue as Partial<DailyCapCounters>;
  if (
    typeof candidateCounters.utcDay !== "string" ||
    !isWholeNumberOfZeroOrMore(candidateCounters.chatRequests) ||
    !isWholeNumberOfZeroOrMore(candidateCounters.textToSpeechCharacters)
  ) {
    return undefined;
  }
  return {
    utcDay: candidateCounters.utcDay,
    chatRequests: candidateCounters.chatRequests,
    textToSpeechCharacters: candidateCounters.textToSpeechCharacters,
  };
}

function jsonResponse(responseObject: unknown, status: number): Response {
  return new Response(JSON.stringify(responseObject), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * The counter: one Durable Object instance, reached only by this Worker
 * (a Durable Object has no public address). It answers
 * `{ counterName, amount, limit }` with `{ allowed }` and stores today's
 * counters under one key. It uses the classic `fetch` handler instead of RPC,
 * because RPC needs a newer compatibility date than the proxy's, and moving
 * that date would change how the rest of the proxy behaves.
 *
 * Reading, deciding and writing cannot interleave with another request: a
 * Durable Object delivers no other request while its storage call is running.
 */
export class ClickyDailyCap {
  private readonly objectState: DailyCapObjectState;

  constructor(objectState: DailyCapObjectState) {
    this.objectState = objectState;
  }

  async fetch(request: Request): Promise<Response> {
    let countRequest: { counterName?: unknown; amount?: unknown; limit?: unknown };
    try {
      countRequest = (await request.json()) as typeof countRequest;
    } catch {
      return jsonResponse({ error: "the count request is not JSON" }, 400);
    }

    const { counterName, amount, limit } = countRequest;
    if (
      (counterName !== "chatRequests" && counterName !== "textToSpeechCharacters") ||
      !isWholeNumberOfZeroOrMore(amount) ||
      !isWholeNumberOfZeroOrMore(limit)
    ) {
      return jsonResponse({ error: "the count request has the wrong shape" }, 400);
    }

    const storedValue = await this.objectState.storage.get(DAILY_COUNTERS_STORAGE_KEY);
    const decision = decideDailyCapRequest(
      storedCountersOrUndefined(storedValue),
      utcDayOf(new Date()),
      counterName,
      amount,
      limit
    );
    if (decision.isAllowed) {
      await this.objectState.storage.put(DAILY_COUNTERS_STORAGE_KEY, decision.countersAfterRequest);
    }
    return jsonResponse({ allowed: decision.isAllowed }, 200);
  }
}
