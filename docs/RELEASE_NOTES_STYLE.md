# GitHub release notes style

GitHub release notes are SakuraCord's detailed, durable account of a release.
They serve users who want the full change summary, contributors investigating
when behavior changed, and the Sparkle update interface. They are not the same
copy as the shorter Discord announcement.

## Establish the release scope first

Before drafting any copy:

1. Resolve the exact tag requested by the maintainer. Do not infer that the
   next semantic version is intended merely because a newer commit exists.
2. Inspect the current GitHub Release, if one exists, to distinguish a new
   release from a release whose notes need to be backfilled or repaired.
3. Compare the previous release tag with the requested tag and review the
   relevant commits, code, tests, and documentation. Commit subjects are an
   index, not sufficient evidence on their own.
4. Include only behavior that is actually present in the tagged tree. Do not
   describe later release-automation or unreleased work.

## Layout

Use this consistent order:

1. One opening paragraph naming the version and summarizing its major features
   and overall improvements.
2. Three to six sentence-case `##` sections grouped by user-recognizable area,
   such as `## Messaging and attachments`, `## GIFs and media`, or
   `## Performance and reliability`.
3. Complete-sentence bullets under each section.
4. A linked comparison as the final line:

   ```markdown
   **Full Changelog:** [vPREVIOUS...vCURRENT](https://github.com/SakuraCordApp/SakuraCord/compare/vPREVIOUS...vCURRENT)
   ```

Put user-facing features and fixes first. Follow them with performance,
reliability, safety, compatibility, testing, or maintenance work when those
details are meaningful for the release record.

## Wording

- Use direct past-tense descriptions such as `Added`, `Improved`, `Fixed`, and
  `Reduced`.
- Describe the resulting behavior instead of narrating individual commits or
  implementation steps.
- Combine closely related changes into one useful bullet, but do not collapse
  unrelated work into vague claims.
- Use specific, descriptive section headings. Avoid generic marketing headings
  such as `What's new`, `More to love`, `Better than ever`, or `Everything is
  smoother` when a concrete product area can be named.
- Name major features, workflows, visible results, and technical outcomes
  directly. Do not reduce clearly identifiable additions to abstract benefits
  such as `new ways to share and browse`.
- Broad phrases such as `quality-of-life improvements` or `overall experience`
  are acceptable when they accurately group numerous minor, unrelated polish
  changes. They must not substitute for major features, and the detailed
  sections should include representative concrete changes.
- Keep claims proportional to verified evidence. Avoid superlatives,
  unsupported compatibility claims, and claims that an incomplete feature is
  finished.
- Do not add emoji to GitHub release notes.

Technical details are appropriate when they explain a user-visible reliability
improvement or form an important part of the durable release record. Avoid
flooding the notes with internal class names, test counts, roadmap bookkeeping,
or CI mechanics that do not affect the shipped app.

Before presenting a draft, perform a specificity pass. Confirm that every
major feature is named, every broad summary is supported by representative
details, and filler that communicates neither is removed.

## Template

```markdown
SakuraCord vX.Y.Z adds [major features]. It also improves [important areas].

## Specific product area

- Added [complete description].
- Improved [complete description].

## Performance and reliability

- Reduced [specific problem or cost].
- Fixed [specific behavior].

**Full Changelog:** [vPREVIOUS...vX.Y.Z](https://github.com/SakuraCordApp/SakuraCord/compare/vPREVIOUS...vX.Y.Z)
```

## Review and storage

Present the complete draft to the maintainer for revision before writing a
release-copy file unless the maintainer explicitly asked to save immediately.
After approval, store the exact reviewed Markdown in `githubDescription` within
`Releases/vX.Y.Z.json`. Do not silently rewrite it into Discord copy.
