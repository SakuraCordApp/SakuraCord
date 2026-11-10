// Publish one combined assessment. The hub applies its hidden, validated result.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolveFix } from "./release-evidence.mjs";

const number = process.env.ISSUE_NUMBER;
const repo = process.env.GITHUB_REPOSITORY;
const sha = process.env.SOURCE_SHA;
const run = `${process.env.GITHUB_SERVER_URL}/${repo}/actions/runs/${process.env.GITHUB_RUN_ID}`;
const result = JSON.parse(readFileSync(process.env.RESULT_PATH, "utf8"));
const context = JSON.parse(readFileSync(join(process.env.RUNNER_TEMP, "assessment-context.json"), "utf8"));
const triage = result.triage;
// The hub allows a bounded number of question rounds; after that, open
// questions are left for a maintainer instead of asking the reporter again.
let openQuestions = [];
if (context.questionsAllowed === false && triage) {
  if (triage.needsInformation) openQuestions = triage.questions ?? [];
  Object.assign(triage, { needsInformation: false, questions: [] });
}
if (context.number !== Number(number) || !context.areas.includes(triage?.area) ||
    (triage.duplicateOf !== null && (!context.candidates.includes(triage.duplicateOf) || triage.duplicateOf === Number(number))) ||
    (triage.needsInformation && !triage.questions.length)) throw new Error("Invalid assessment result");
const resolution = resolveFix(result.fixCommit, context.refs);
const releaseLink = resolution.release ? `[${resolution.release.version} (${resolution.release.channel})](${resolution.release.url})` : "";
// The hub applies a found fix on its own only at high confidence.
const pending = resolution.commit && resolution.state.startsWith("fixed_") && result.confidence !== "high"
  ? " A maintainer will confirm it before the report's status changes." : "";
const availability = {
  unresolved: "No existing fix has been verified.",
  possible_regression: `The reported release already contains this change. This may be a regression or incomplete fix and still needs investigation.`,
  fixed_regular: `The fix is available in ${releaseLink}. Update and retest on that release.`,
  fixed_nightly: `The fix is available in ${releaseLink}, but not in the latest regular release. You can try nightly or wait for the next regular release.`,
  fixed_unreleased: "The fix is in the app's code, but is not in either latest published release yet. No released update contains it yet.",
}[resolution.state] + pending;
if (resolution.state === "possible_regression") triage.duplicateOf = null;
triage.resolution = { state: resolution.state, commit: resolution.commit, releaseTag: resolution.release?.tag ?? null, explanation: availability };
const envelope = JSON.stringify({ version: 1, number: Number(number), sourceTitle: context.sourceTitle,
  bodyHash: context.bodyHash, confidence: result.confidence, candidates: context.candidates, model: process.env.AGENT_MODEL, triage,
}).replaceAll("<", "\\u003c").replaceAll(">", "\\u003e");
const clean = (text) => String(text ?? "").replace(/@(?=[A-Za-z0-9-])/g, "@​").trim();
const locations = result.locations
  .filter((location) => /^[\w./ -]+$/.test(location.path))
  .map(
    (location) =>
      `- [\`${location.path}:${location.line}\`](https://github.com/${repo}/blob/${sha}/${location.path.split("/").map(encodeURIComponent).join("/")}#L${location.line}) — ${clean(location.reason)}`,
  )
  .join("\n");
const body = `<!-- sakuracord:investigation -->
<!-- sakuracord:agent-run investigate ${process.env.GITHUB_RUN_ID} ${process.env.GITHUB_RUN_ATTEMPT} -->
### Summary
${clean(result.summary)}

### Triage
**${triage.kind === "bug" ? "Bug" : "Feature"}** · ${clean(triage.area)} · ${clean(triage.priority)} priority
${clean(triage.summary)}

${clean(result.classificationReason)}

### Fix availability
${availability}${resolution.commit ? ` [Change](https://github.com/${repo}/commit/${resolution.commit}).` : ""}
${triage.duplicateOf && triage.duplicateConfidence >= 0.75 ? `
### Possible duplicate
This may match #${triage.duplicateOf}. ${clean(triage.duplicateReason)} A maintainer will decide whether to merge them.
` : ""}
${triage.needsInformation ? `
### Questions
${triage.questions.map((question) => `- ${clean(question)}`).join("\n")}
` : ""}${openQuestions.length ? `
### Open questions for a maintainer
${openQuestions.map((question) => `- ${clean(question)}`).join("\n")}
` : ""}
### Likely locations
${locations || "_No specific location identified._"}

### Probable cause
${clean(result.cause)}

### Suggested fix
${clean(result.suggestedFix)}

### Suggested test
${clean(result.suggestedTest)}

<sub>🔎 Triage & investigation agent · confidence **${result.confidence}** · ${result.fixable ? "looks fixable — a maintainer can add the `agent: fix` label to open a draft PR" : "probably needs a maintainer"} · [run](${run}) · based on \`${sha.slice(0, 7)}\` (nightly) · read ${context.lastComment ? `replies up to ${context.lastComment.replace("T", " ").slice(0, 16)} UTC` : "the report; there were no replies"}</sub>

<!-- sakuracord:triage-result ${envelope} -->`;
writeFileSync("comment.md", body);
const existing = execFileSync(
  "gh",
  [
    "api",
    `repos/${repo}/issues/${number}/comments`,
    "--paginate",
    "--jq",
    '.[] | select(.user.login == "github-actions[bot]" and (.body | startswith("<!-- sakuracord:investigation -->"))) | .id',
  ],
  { encoding: "utf8" },
)
  .split("\n")
  .filter(Boolean);
if (existing.length) {
  execFileSync("gh", ["api", "-X", "PATCH", `repos/${repo}/issues/comments/${existing[existing.length - 1]}`, "-F", "body=@comment.md"], { stdio: "inherit" });
} else {
  execFileSync("gh", ["issue", "comment", number, "--body-file", "comment.md"], { stdio: "inherit" });
}
