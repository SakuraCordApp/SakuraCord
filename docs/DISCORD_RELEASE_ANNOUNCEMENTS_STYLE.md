# Discord release announcement style

Discord announcements are concise, user-facing companions to the detailed
GitHub release notes. They highlight what people can now do or will notice and
send readers to the release page for the full record. They do not need to use
the same wording or cover every GitHub release-note section.

## Generated framing

The release action generates these elements; do not author them in the release
copy:

- the updates-role mention;
- the embed title, `SakuraCord vX.Y.Z`, derived from `tagName`; and
- the **View release** button and its GitHub Release URL.

Only the embed description belongs in `discordAnnouncement`.

## Layout

Use this consistent order:

1. A short, feature-specific headline in bold, ending with `🌸`.
2. One short paragraph describing the release and its overall value.
3. The bold heading `**Highlights**`.
4. Four to six concise bullets focused on user-facing features and recognizable
   improvements.

```markdown
**[Feature-specific headline] 🌸**

[One or two short sentences describing the update.]

**Highlights**

- [User-facing feature or outcome]
- [User-facing feature or outcome]
- [Visible improvement or recognizable fix]
```

## Headline guidance

Name the features or theme that make this particular release recognizable.
Good headlines are concrete, for example:

- `**Message forwarding, GIFs, and a new media viewer 🌸**`
- `**Discord forum channels have arrived! 🌸**`

Do not use generic promotional phrases that could describe any release, such
as `More ways to connect, share, and explore`, `Something for everyone`,
`Better than ever`, or `A new update is available`. Avoid hype, filler, and
unsupported superlatives.

The headline and description must pass this specificity test: do not replace
clearly nameable features with an abstract description of what those features
loosely enable. If a release adds message forwarding, a GIF picker, and a media
viewer, name them instead of calling them `new ways to share and browse`.

Reject abstract umbrella phrases when the underlying feature can be named.
Examples that must be rewritten include:

- `adds new ways to share and browse content`;
- `makes everything faster and easier`;
- `includes several exciting new features`;
- `offers a smoother and more polished experience`.

Replace them with the actual behavior, such as `Forward messages between
conversations, search and send GIFs from a native picker, and browse
attachments in a rebuilt media viewer.` Highlights bullets cannot justify
hiding a few clearly nameable headline features behind an abstract description.

Broad language such as `quality-of-life improvements` or `improves the overall
experience` is acceptable when it truthfully groups many small, unrelated
polish changes that would be noisy to enumerate in the short description. It
must not replace major features that can be named, and the announcement's
Highlights should still provide representative concrete examples.

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
4. Check that the headline and description add information beyond saying that
   an update exists.

## Review and storage

Present the GitHub notes and Discord announcement as separate drafts in the
same review. Make their different scope explicit. Do not write
`Releases/vX.Y.Z.json` until the maintainer approves the copy unless they
explicitly asked to save immediately. After approval, store only the authored
embed description in `discordAnnouncement`; the action adds all generated
framing at publication time.
