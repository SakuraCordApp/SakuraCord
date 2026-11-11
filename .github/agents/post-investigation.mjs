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
const fixPullRequest = result.fixPullRequest ?? null;
// The hub allows a bounded number of question rounds; after that, open
// questions are left for a maintainer instead of asking the reporter again.
let openQuestions = [];
if (context.questionsAllowed === false && triage) {
  if (triage.needsInformation) openQuestions = triage.questions ?? [];
  Object.assign(triage, { needsInformation: false, questions: [] });
}
if (context.number !== Number(number) || !context.areas.includes(triage?.area) ||
    (triage.duplicateOf !== null && (!context.candidates.includes(triage.duplicateOf) || triage.duplicateOf === Number(number))) ||
    (triage.needsInformation && !triage.questions.length) ||
    (fixPullRequest !== null && !context.pullRequests.includes(fixPullRequest))) throw new Error("Invalid assessment result");
const resolution = resolveFix(result.fixCommit, context.refs);
if (resolution.state === "possible_regression") triage.duplicateOf = null;
const duplicate = triage.duplicateOf && result.findings?.duplicate === "high";
const releaseLink = resolution.release ? `[${resolution.release.version} (${resolution.release.channel})](${resolution.release.url})` : "";
// Mirrors when the hub applies a fix on its own: rated high (for results without
// ratings, high overall confidence), no questions, and no duplicate holding it back.
const fixApplies = !triage.needsInformation && (result.findings
  ? result.findings.fix === "high" && !duplicate : result.confidence === "high" && !triage.duplicateOf);
const pending = resolution.commit && resolution.state.startsWith("fixed_") && !duplicate && !fixApplies
  ? " A maintainer will confirm it before the report is marked fixed." : "";
// The hub links a pull request rated high, unless it applies a fix instead.
const linksPull = result.findings?.pullRequest === "high" && !triage.needsInformation && !duplicate &&
  !(fixApplies && resolution.state.startsWith("fixed_"));
const pullRequest = !fixPullRequest ? "" : linksPull
  ? ` Pull request #${fixPullRequest} ${triage.kind === "feature" ? "implements" : "fixes"} it; the hub adds "Fixes #${number}" to it, so it is tracked like any linked pull request.`
  : ` Pull request #${fixPullRequest} is open to ${triage.kind === "feature" ? "implement" : "fix"} it.`;
const availability = {
  unresolved: "No existing fix has been verified.",
  possible_regression: `The reported release already contains this change. This may be a regression or incomplete fix and still needs investigation.`,
  fixed_regular: `The fix is available in ${releaseLink}. Update and retest on that release.`,
  fixed_nightly: `The fix is available in ${releaseLink}, but not in the latest regular release. You can try nightly or wait for the next regular release.`,
  fixed_unreleased: "The fix is in the app's code, but is not in either latest published release yet. No released update contains it yet.",
}[resolution.state] + pending + pullRequest;
triage.resolution = { state: resolution.state, commit: resolution.commit, releaseTag: resolution.release?.tag ?? null,
  pullRequest: fixPullRequest, explanation: availability };
// sourceKind lets the hub keep a category a maintainer changed during the run.
const envelope = JSON.stringify({ version: 1, number: Number(number), sourceTitle: context.sourceTitle, sourceKind: context.reportedKind ?? null,
  bodyHash: context.bodyHash, confidence: result.confidence, findings: result.findings, candidates: context.candidates, model: process.env.AGENT_MODEL, triage,
}).replaceAll("<", "\\u003c").replaceAll(">", "\\u003e");
// Model text must not open or close an HTML comment: the hub reads its result
// from the marker at the end, and a quoted marker could pass for one.
const clean = (text) => String(text ?? "").replace(/@(?=[A-Za-z0-9-])/g, "@​")
  .replaceAll("<!--", "&lt;!--").replaceAll("-->", "--&gt;").trim();
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
${duplicate ? `
### Duplicate
This matches #${triage.duplicateOf}. ${clean(triage.duplicateReason)}
` : triage.duplicateOf && triage.duplicateConfidence >= 0.75 ? `
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
