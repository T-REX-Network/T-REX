// Gitmoji commit convention, as described in CONTRIBUTING.md:
//
//   <emoji> [scope?][:?] <message>
//
//   ♻️ Reuse the publish helper when seeding the initial version
//   📝 (compliance): Explain how the bind nonce wipes module storage

// One emoji, allowing a variation selector, a skin-tone modifier and ZWJ sequences.
const EMOJI = '[\\p{Extended_Pictographic}\\u{1F3FB}-\\u{1F3FF}\\u200D\\uFE0F]+';

// Or its `:shortcode:` spelling, which gitmoji.dev also publishes.
const SHORTCODE = ':[a-z0-9_+-]+:';

const HEADER = new RegExp(
    `^(${EMOJI}|${SHORTCODE}):?[ ]+` // intention
        + `(?:\\(([^)]+)\\)[ ]*:?[ ]*)?` // optional scope
        + `(.+)$`, // message
    'u'
);

module.exports = {
    parserPreset: {
        parserOpts: {
            headerPattern: HEADER,
            headerCorrespondence: ['type', 'scope', 'subject'],
        },
    },
    rules: {
        // A header that does not match HEADER parses to a null type, so this is
        // also what reports a malformed message.
        'type-empty': [2, 'never'],
        'subject-empty': [2, 'never'],
        'header-max-length': [2, 'always', 100],
        'body-leading-blank': [2, 'always'],
        'footer-leading-blank': [2, 'always'],
    },
    prompt: {
        messages: {
            skip: '(press enter to skip)',
        },
    },
};
