# Discord release announcement style

Discord announcements are concise, user-facing companions to the detailed
GitHub release notes. They highlight what people can now do or will notice and
send readers to the release page for the full record. They do not need to use
the same wording or cover every GitHub release-note section.

## Generated framing

The release action generates these elements; do not author them in the release
copy:

- the updates-role mention;
- the embed title, derived from `tagName` (nightly titles also end in `🌙`); and
- the **View release** button and its GitHub Release URL.

Only the embed description belongs in `discordAnnouncement`.

## Layout

Use this consistent order:

1. A short, feature-specific headline in bold, ending with `🌸` for regular
   releases or `🌙` for nightly releases.
2. The bold heading `**Highlights**`.
3. Four to six concise bullets focused on user-facing features and recognizable
   improvements.

Do not add an introductory paragraph between the custom headline and
`**Highlights**`; the bullets carry the release details. Use exactly one blank
line between the two headings, and put the first bullet immediately after
`**Highlights**`. This is an intentional Discord embed layout rule, not
optional Markdown styling.

```markdown
**[Feature-specific headline] 🌸**

**Highlights**
- [User-facing feature or outcome]
- [User-facing feature or outcome]
- [Visible improvement or recognizable fix]
```

For a nightly tag, replace only that headline emoji with the moon:

```markdown
**[Feature-specific nightly headline] 🌙**

**Highlights**
- [User-facing feature or outcome]
```

The action also gives nightly embeds a distinct indigo color and routes them to
the nightly channel with the nightly updates-role mention. Keep the authored
copy free of role, user, `@here`, and `@everyone` mentions for both tracks.

## Headline guidance

Name the features or theme that make this particular release recognizable.
Good headlines are concrete, for example:

- `**Message forwarding, GIFs, and a new media viewer 🌸**`
- `**Discord forum channels have arrived! 🌸**`
- `**Message forwarding and GIF fixes are ready to test 🌙**` (nightly only)

Do not use generic promotional phrases that could describe any release, such
as `More ways to connect, share, and explore`, `Something for everyone`,
`Better than ever`, or `A new update is available`. Avoid hype, filler, and
unsupported superlatives.

The headline and bullets must pass this specificity test: do not replace
clearly nameable features with an abstract description of what those features
loosely enable. If a release adds message forwarding, a GIF picker, and a media
viewer, name them instead of calling them `new ways to share and browse`.

Reject abstract umbrella phrases when the underlying feature can be named.
Examples that must be rewritten include:

- `adds new ways to share and browse content`;
- `makes everything faster and easier`;
- `includes several exciting new features`;
- `offers a smoother and more polished experience`.

Replace them with the actual feature names. Highlights bullets cannot justify
hiding a few clearly nameable headline features behind an abstract heading.

Broad language such as `quality-of-life improvements` is acceptable in a
bullet when it truthfully groups many small, unrelated polish changes that
would be noisy to enumerate. It must not replace major features that can be
named, and nearby bullets should still provide representative concrete
examples.

## Wording and selection

- Prefer features, visible improvements, and recognizable fixes over internal
  architecture, CI, testing, licensing, or implementation terminology.
- Write short, natural bullets with varied sentence structure. Do not force
  every bullet to begin with an imperative verb.
- Describe outcomes in familiar product language. A user should not need to
  know the source tree or Discord protocol internals to understand a bullet.
- Combine smaller reliability improvements when necessary, but do not use a
  vague phrase as a substitute for the release's main features.
- Do not repeat the version in the authored description; the generated embed
  title already supplies it.
- Keep the full announcement comfortably scannable. Aim for approximately
  500–800 characters and stay within the validator's hard limit.

Before presenting a draft, perform a specificity pass:

1. Identify every major, clearly nameable feature and confirm that it appears
   by name rather than as an abstract benefit.
2. Check that broad quality-of-life wording represents genuinely diffuse polish
   and is supported by representative concrete bullets.
3. Remove introductory filler instead of paraphrasing it.
4. Check that the headline adds information beyond saying that an update
   exists.
5. Preview the raw line breaks: there must be exactly one blank line between
   the custom headline and `**Highlights**`, no paragraph between them, and the
   first bullet must immediately follow `**Highlights**`.

## Review and storage

Present the GitHub notes and Discord announcement as separate drafts in the
same review. Make their different scope explicit. Do not write
`Releases/vX.Y.Z.json` until the maintainer approves the copy unless they
explicitly asked to save immediately. After approval, store only the authored
embed description in `discordAnnouncement`; the action adds all generated
framing at publication time.
