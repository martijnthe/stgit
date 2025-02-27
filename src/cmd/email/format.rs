// SPDX-License-Identifier: GPL-2.0-only

//! `stg email format` implementation.

use anyhow::{anyhow, Result};
use clap::Arg;

use crate::{
    argset,
    ext::{CommitExtended, RepositoryExtended},
    patch::patchrange,
    stack::{Error, InitializationPolicy, Stack, StackStateAccess},
    stupid::Stupid,
};

pub(super) fn command() -> clap::Command {
    clap::Command::new("format")
        .about("Format patches as email files")
        .long_about(
            "Format selected patches as email files, one patch per file. The files are \
             formatted to resemble a UNIX mailbox (mbox) and may be sent with the `stg \
             email send` command. The first line of the patch's commit message is used \
             to form the email's subject with the remainder of the message in the \
             email's body.\n\
             \n\
             The patches to format may be specified as individual patch names or patch \
             ranges of the form 'p0..p3', or '--all' may be used to format all applied \
             patches. Note that the specified patches must be contiguous within the \
             patch series.\n\
             \n\
             By default, the email files will be output to the current directory, \
             however use of the -o/--output-directory option is recommended since \
             sending the email with `stg email send <dir>` is simpler than specifying \
             all the email files individually.\n\
             \n\
             A cover letter template may also be generated by specifying \
             '--cover-letter'. A cover letter is recommended when sending multiple \
             patches. The `format.coverLetter` configuration value may be set true to \
             always generate a cover letter or 'auto' to generate a cover letter when \
             formatting more than one patch.\n\
             \n\
             Recipients may be specified using the '--to' and '--cc', or setting \
             recipients may be deferred to `stg email send`.\n\
             \n\
             Many aspects of the format behavior may be controlled via `format.*` \
             configuration values. Refer to the git-config(1) and git-format-patch(1) \
             man pages for more details.",
        )
        .override_usage(
            "stg email format [OPTIONS] <patch>...\n       \
             stg email format [OPTIONS] --all",
        )
        .arg(
            Arg::new("patchranges")
                .help("Patches to format")
                .value_name("patch")
                .num_args(1..)
                .value_parser(clap::value_parser!(patchrange::Specification))
                .conflicts_with("all")
                .required_unless_present_any(["all"]),
        )
        .arg(argset::branch_arg())
        .arg(
            Arg::new("all")
                .long("all")
                .short('a')
                .help("Format all applied patches")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("git-format-patch-opt")
                .long("git-opt")
                .short('G')
                .help("Pass additional <option> to `git format-patch`")
                .long_help(
                    "Pass additional <option> to `git format-patch`.\n\
                     \n\
                     See the git-format-patch(1) man page. This option may be \
                     specified multiple times.",
                )
                .allow_hyphen_values(true)
                .action(clap::ArgAction::Append)
                .value_name("option"),
        )
        .next_help_heading("Format Options")
        .args(format_options())
        .next_help_heading("Message Options")
        .args(message_options())
    // DIFF OPTIONS ???
}

fn format_options() -> Vec<Arg> {
    vec![
        Arg::new("output-directory")
            .long("output-directory")
            .short('o')
            .help("Store output files in <dir>")
            .long_help(
                "Use <dir> to store the output files instead of the \
                 current working directory.",
            )
            .num_args(1)
            .value_name("dir")
            .value_hint(clap::ValueHint::DirPath)
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("cover-letter")
            .long("cover-letter")
            .help("Generate a cover letter")
            .long_help(
                "In addition to the patches, generate a cover letter file containing \
                 the branch description, shortlog and the overall diffstat. You can \
                 fill in a description in the file before sending it out.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("numbered")
            .long("numbered")
            .short('n')
            .help("Use [PATCH n/m] even with a single patch")
            .action(clap::ArgAction::SetTrue),
        Arg::new("no-numbered")
            .long("no-numbered")
            .short('N')
            .help("Use [PATCH] even with multiple patches")
            .conflicts_with("numbered")
            .action(clap::ArgAction::SetTrue),
        Arg::new("start-number")
            .long("start-number")
            .help("Start numbering at <n> instead of 1")
            .value_name("n")
            .num_args(1),
        Arg::new("reroll-count")
            .long("reroll-count")
            .short('v')
            .help("Mark the series as the <n>th reroll")
            .long_help(
                "Mark the series as the <n>-th iteration of the topic. The output \
                 filenames have \"v<n>\" prepended to them, and the subject prefix \
                 (\"PATCH\" by default, but configurable via the --subject-prefix \
                 option) has ` v<N>` appended to it. E.g. '--reroll-count=4' may \
                 produce v4-0001-add-makefile.patch file that has \"Subject: [PATCH v4
                 1/20] Add makefile\" in it. <N> does not have to be an integer (e.g. \
                 '--reroll-count=4.4', or '--reroll-count=4rev2' are allowed), but the \
                 downside of using such a reroll-count is that the \
                 range-diff/interdiff with the previous version does not state exactly \
                 which version the new iteration is compared against.",
            )
            .value_name("n")
            .num_args(1),
        Arg::new("rfc")
            .long("rfc")
            .help("Use [RFC PATCH] instead of [PATCH]")
            .long_help(
                "Alias for '--subject-prefix=\"RFC PATCH\"'. RFC means \"Request For \
                 Comments\"; use this when sending an experimental patch for \
                 discussion rather than application.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("subject-prefix")
            .long("subject-prefix")
            .help("Use [<prefix>] instead of [PATCH]")
            .long_help(
                "Instead of the standard `[PATCH]` prefix in the subject line, instead \
                 use `[<prefix>]`. This allows for useful naming of a patch series, \
                 and can be combined with the '--numbered' option.",
            )
            .value_name("prefix")
            .num_args(1),
        Arg::new("quiet")
            .long("quiet")
            .help("Do not print the names of the generated files")
            .action(clap::ArgAction::SetTrue),
        Arg::new("signoff")
            .long("signoff")
            .short('s')
            .help("Add a Signed-off-by trailer")
            .long_help(
                "Add a Signed-off-by trailer to the commit message, using the \
                 committer identity of yourself. See the signoff option in \
                 git-commit(1) for more information.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("numbered-files")
            .long("numbered-files")
            .help("Use simple number sequence for output file names")
            .long_help(
                "Output file names will be a simple number sequence without the \
                 default first line of the commit appended.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("suffix")
            .long("suffix")
            .help("Use <suffix> instead of '.patch'")
            .long_help(
                "Instead of using `.patch` as the suffix for generated filenames, use \
                 specified suffix. A common alternative is '--suffix=.txt'. Leaving \
                 this empty will remove the `.patch` suffix.",
            )
            .value_name("suffix")
            .num_args(1)
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("keep-subject")
            .long("keep-subject")
            .short('k')
            .help("Do not strip/add [PATCH]")
            .long_help(
                "Do not strip/add `[PATCH]` from the first line of the commit log \
                 message.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("no-binary")
            .long("no-binary")
            .help("Do not output binary diffs")
            .long_help(
                "Do not output contents of changes in binary files, instead display a \
                 notice that those files changed. Patches generated using this option \
                 cannot be applied properly, but they are still useful for code \
                 review.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("zero-commit")
            .long("zero-commit")
            .help("Output all-zero hash in From header")
            .long_help(
                "Output an all-zero hash in each patch’s `From` header instead of the \
                 hash of the commit.",
            )
            .action(clap::ArgAction::SetTrue),
        // NO --filename-max-length
        // NO --cover-from-description
        // NO --ignore-if-in-upstream
    ]
}

fn message_options() -> Vec<Arg> {
    vec![
        Arg::new("to")
            .long("to")
            .help("Specify a To: address for each email")
            .long_help(
                "Add a `To:` header to the email headers. This is in addition to any \
                 configured headers, and may be used multiple times. The negated form \
                 '--no-to' discards all `To:` headers added so far (from config or \
                 command line).",
            )
            .value_name("address")
            .num_args(1)
            .value_parser(clap::builder::NonEmptyStringValueParser::new())
            .action(clap::ArgAction::Append)
            .value_hint(clap::ValueHint::EmailAddress),
        Arg::new("no-to")
            .long("no-to")
            .help("Discard all To: headers added so far")
            .long_help("Discard all `To:` addresses added so far from config or command line.")
            .action(clap::ArgAction::SetTrue),
        Arg::new("cc")
            .long("cc")
            .help("Specify a Cc: address for each email")
            .long_help(
                "Add a `Cc:` header to the email headers. This is in addition to any \
                 configured headers, and may be used multiple times. The negated form \
                 '--no-cc' discards all `Cc:` headers added so far (from config or \
                 command line).",
            )
            .value_name("address")
            .num_args(1)
            .value_parser(clap::builder::NonEmptyStringValueParser::new())
            .action(clap::ArgAction::Append)
            .value_hint(clap::ValueHint::EmailAddress),
        Arg::new("no-cc")
            .long("no-cc")
            .help("Discard all Cc: addresses added so far")
            .long_help("Discard all `Cc:` addresses added so far from config or command line.")
            .action(clap::ArgAction::SetTrue),
        Arg::new("in-reply-to")
            .long("in-reply-to")
            .help("Make first mail a reply to <message-id>")
            .long_help(
                "Make the first mail (or all the mails with '--no-thread') appear as a \
                 reply to the given <message-id>, which avoids breaking threads to \
                 provide a new patch series.",
            )
            .value_name("message-id")
            .num_args(1)
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("add-header")
            .long("add-header")
            .help("Add an arbitrary email header")
            .long_help(
                "Add an arbitrary header to the email headers. This is in addition to \
                 any configured headers, and may be used multiple times. For example, \
                 '--add-header=\"Organization: git-foo\"'.",
                // "The negated form '--no-add-header' discards all (`To:`, `Cc:`, \
                //  and custom)  headers added so far from config or command line."
            )
            .value_name("header")
            .num_args(1)
            .value_parser(clap::builder::NonEmptyStringValueParser::new())
            .action(clap::ArgAction::Append),
        // N.B. not supporting the optional mime-boundary value
        Arg::new("attach")
            .long("attach")
            .help("Attach the patch")
            .long_help(
                "Create multipart/mixed attachment, the first part of which is the \
                 commit message and the patch itself in the second part, with \
                 `Content-Disposition:` attachment.",
            )
            .action(clap::ArgAction::SetTrue),
        // N.B. not supporting the optional mime-boundary value
        Arg::new("inline")
            .long("inline")
            .help("Inline the patch")
            .long_help(
                "Create multipart/mixed attachment, the first part of which is the \
                 commit message and the patch itself in the second part, with \
                 `Content-Disposition: inline`.",
            )
            .action(clap::ArgAction::SetTrue),
        Arg::new("thread")
            .long("thread")
            .help("Enable message threading, styles: shallow or deep")
            .long_help(
                "Controls addition of `In-Reply-To` and `References` headers to make \
                 the second and subsequent mails appear as replies to the first. Also \
                 controls generation of the `Message-Id` header to reference.\n\
                 \n\
                 The optional <style> argument can be either `shallow` or `deep`. \
                 `shallow` threading makes every mail a reply to the head of the \
                 series, where the head is chosen from the cover letter, the \
                 '--in-reply-to', and the first patch mail, in this order. `deep` \
                 threading makes every mail a reply to the previous one.\n\
                 \n\
                 The default is '--no-thread', unless the `format.thread` \
                 configuration is set. If '--thread' is specified without a style, it \
                 defaults to the style specified by `format.thread` if any, or else \
                 `shallow`.\n\
                 \n\
                 Beware that the default for `git send-email` is to thread emails \
                 itself. If you want `git format-patch` to take care of threading, you \
                 will want to ensure that threading is disabled for `git send-email`.",
            )
            .value_name("style")
            .hide_possible_values(true)
            .value_parser(["shallow", "deep", ""])
            .num_args(0..=1)
            .default_missing_value("")
            .require_equals(true),
        Arg::new("no-thread")
            .long("no-thread")
            .help("Disable message threading")
            .action(clap::ArgAction::SetTrue),
        Arg::new("signature")
            .long("signature")
            .help("Add a signature to each email")
            .long_help(
                "Add a signature string to each email. The default signature is the \
                 git version number, or the `format.signature` configuration value, if \
                 specified. The signature may be disabled with '--no-signature'",
            )
            .num_args(1)
            .value_name("signature")
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("no-signature")
            .long("no-signature")
            .help("Do not add a signature to each email")
            .action(clap::ArgAction::SetTrue),
        Arg::new("signature-file")
            .long("signature-file")
            .help("Add a signature from a file")
            .long_help("Like '--signature' except the signature is read from a file.")
            .num_args(1)
            .value_name("file")
            .value_hint(clap::ValueHint::FilePath),
        Arg::new("base")
            .long("base")
            .help("Add prerequisite tree info to the patch series")
            .long_help("See the BASE TREE INFORMATION section of git-format-patch(1).")
            .num_args(1)
            .value_name("committish")
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("progress")
            .long("progress")
            .help("Show progress while generating patches")
            .long_help("Show progress reports on stderr as patches are generated.")
            .action(clap::ArgAction::SetTrue),
        Arg::new("interdiff")
            .long("interdiff")
            .help("Show changes against <rev> in cover letter")
            .long_help(
                "As a reviewer aid, insert an interdiff into the cover letter, or as \
                 commentary of the lone patch of a 1-patch series, showing the \
                 differences between the previous version of the patch series and the \
                 series currently being formatted. <rev> is a single revision naming \
                 the tip of the previous series which shares a common base with the \
                 series being formatted (for example `git format-patch --cover-letter \
                 --interdiff=feature/v1 -3 feature/v2`).",
            )
            .num_args(1)
            .value_name("rev")
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("range-diff")
            .long("range-diff")
            .help("Show changes against <refspec> in cover letter")
            .long_help(
                "As a reviewer aid, insert a range-diff (see git-range-diff(1)) into \
                 the cover letter, or as commentary of the lone patch of a \
                 single-patch series, showing the differences between the previous \
                 version of the patch series and the series currently being formatted. \
                 <refspec> can be a single revision naming the tip of the previous \
                 series if it shares a common base with the series being formatted \
                 (for example `git format-patch --cover-letter --range-diff=feature/v1 \
                 -3 feature/v2`), or a revision range if the two versions of the \
                 series are disjoint (for example `git format-patch --cover-letter \
                 --range-diff=feature/v1~3..feature/v1 -3 feature/v2`).\n\
                 \n\
                 Note that diff options passed to the command affect how the primary \
                 product of `format-patch` is generated, and they are not passed to \
                 the underlying `range-diff` machinery used to generate the \
                 cover-letter material (this may change in the future).",
            )
            .num_args(1)
            .value_name("refspec")
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        Arg::new("creation-factor")
            .long("creation-factor")
            .help("Percentage by which creation is weighed")
            .long_help(
                "Used with '--range-diff', tweak the heuristic which matches up \
                 commits between the previous and current series of patches by \
                 adjusting the creation/deletion cost fudge factor. See \
                 git-range-diff(1)) for details.",
            )
            .num_args(1)
            .value_name("n")
            .value_parser(clap::builder::NonEmptyStringValueParser::new()),
        // NO --from
        // NO --no-add-header
    ]
}

pub(super) fn dispatch(matches: &clap::ArgMatches) -> Result<()> {
    let repo = git_repository::Repository::open()?;
    let stack = Stack::from_branch(
        &repo,
        argset::get_one_str(matches, "branch"),
        InitializationPolicy::AllowUninitialized,
    )?;

    let patches =
        if let Some(range_specs) = matches.get_many::<patchrange::Specification>("patchranges") {
            let patches = patchrange::contiguous_patches_from_specs(
                range_specs,
                &stack,
                patchrange::Allow::VisibleWithAppliedBoundary,
            )?;
            if patches.is_empty() {
                return Err(anyhow!("no patches to format"));
            }
            patches
        } else if matches.get_flag("all") {
            let applied = stack.applied();
            if applied.is_empty() {
                return Err(Error::NoAppliedPatches.into());
            }
            applied.to_vec()
        } else {
            panic!("expect either patchranges or -a/--all")
        };

    for patchname in &patches {
        if stack.get_patch_commit(patchname).is_no_change()? {
            return Err(anyhow!("cannot format empty patch `{patchname}`"));
        }
    }

    let mut format_args: Vec<(usize, String)> = Vec::new();

    // This dummy command is constructed with just the Args that are to be
    // passed-through directly to `git format-patch`.
    let mut dummy_command = clap::Command::new("dummy")
        .args(format_options())
        .args(message_options());
    dummy_command.build();

    for arg in dummy_command.get_arguments() {
        let arg_id = arg.get_id().as_str();
        if matches!(
            matches.value_source(arg_id),
            Some(clap::parser::ValueSource::CommandLine)
        ) {
            let num_args = arg.get_num_args().expect("built Arg's num_args is Some");
            let long = arg.get_long().expect("passthrough arg has long option");
            let indices = matches.indices_of(arg_id).expect("value source is cmdline");
            if num_args.takes_values() {
                let values = matches.get_many::<String>(arg_id).unwrap();
                assert!(indices.len() == values.len());
                indices.into_iter().zip(values).for_each(|(index, value)| {
                    if arg_id == "thread" && value.is_empty() {
                        format_args.push((index, format!("--{long}")));
                    } else {
                        format_args.push((index, format!("--{long}={value}")));
                    }
                });
            } else {
                indices.for_each(|index| format_args.push((index, format!("--{long}"))));
            }
        }
    }

    format_args.sort_by_key(|(index, _)| *index);

    let mut format_args = format_args.drain(..).map(|(_, s)| s).collect::<Vec<_>>();

    if let Some(values) = matches.get_many::<String>("git-format-patch-opt") {
        format_args.extend(values.cloned());
    }

    {
        let base = stack
            .get_patch_commit(&patches[0])
            .parent_ids()
            .next()
            .unwrap()
            .detach();
        let last = stack.get_patch_commit(patches.last().unwrap()).id;
        format_args.push(format!("{base}..{last}"));
    }

    repo.stupid().format_patch(format_args)
}
