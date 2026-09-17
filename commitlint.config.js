// Commit messages follow Gitmoji (CONTRIBUTING.md): "<emoji> <imperative sentence>".
// The emoji is a Unicode pictograph (optionally with a variation selector, skin tone or ZWJ sequence)
// or a ":shortcode:", followed by one space and the subject.
const GITMOJI_HEADER =
  /^(?::[a-z0-9_+-]+:|\p{Extended_Pictographic}(?:️|\p{Emoji_Modifier})?(?:‍\p{Extended_Pictographic}️?)*)\s(.+)$/u;

module.exports = {
  parserPreset: {
    parserOpts: {
      headerPattern: GITMOJI_HEADER,
      headerCorrespondence: ["subject"],
    },
  },
  plugins: [
    {
      rules: {
        "gitmoji-header": (parsed) => {
          const header = parsed.header ?? "";
          return [
            GITMOJI_HEADER.test(header),
            'header must be "<gitmoji> <imperative sentence>", e.g. "✨ Add the spender check"',
          ];
        },
      },
    },
  ],
  rules: {
    "gitmoji-header": [2, "always"],
    "header-max-length": [2, "always", 120],
    "body-leading-blank": [2, "always"],
  },
};
