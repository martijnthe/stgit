// SPDX-License-Identifier: GPL-2.0-only

//! `stg files` implementation.

use std::io::Write;

use anyhow::Result;
use bstr::ByteSlice;
use clap::{Arg, ArgMatches};

use crate::{
    ext::{CommitExtended, RepositoryExtended},
    revspec::parse_stgit_revision,
    stupid::Stupid,
};

pub(super) const STGIT_COMMAND: super::StGitCommand = super::StGitCommand {
    name: "files",
    category: super::CommandCategory::PatchInspection,
    make,
    run,
};

fn make() -> clap::Command {
    clap::Command::new(STGIT_COMMAND.name)
        .about("Show files modified by a patch")
        .long_about(
            "Show the files modified by a patch. The files of the topmost \
             patch are shown by default. Passing the '--stat' option shows \
             the diff statistics for the given patch. Note that this command \
             does not show the files modified in the working tree and not yet \
             included in the patch by a 'refresh' command. Use the 'diff' or \
             'status' commands to show these files.",
        )
        .arg(
            Arg::new("stgit-revision")
                .value_name("revision")
                .help("StGit revision"),
        )
        .arg(
            Arg::new("stat")
                .long("stat")
                .short('s')
                .help("Show patch's diffstat")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("bare")
                .long("bare")
                .help("Print bare file names")
                .long_help("Print bare file names. This is useful for scripting.")
                .action(clap::ArgAction::SetTrue)
                .conflicts_with("stat"),
        )
}

fn run(matches: &ArgMatches) -> Result<()> {
    let repo = git_repository::Repository::open()?;
    let opt_spec = crate::argset::get_one_str(matches, "stgit-revision");
    let commit = parse_stgit_revision(&repo, opt_spec, None)?.try_into_commit()?;
    let parent = commit.get_parent_commit()?;
    let mut output = repo.stupid().diff_tree_files_status(
        parent.tree_id()?.detach(),
        commit.tree_id()?.detach(),
        matches.get_flag("stat"),
        matches.get_flag("bare"),
        crate::color::use_color(matches),
    )?;

    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    for line in output.split_inclusive_mut(|b| *b == b'\t') {
        // Replace tab separator with space between status and filename.
        // This is done for compatibility with StGit <2.0.
        if let Some(tab_pos) = line.find_byte(b'\t') {
            line[tab_pos] = b' ';
        }
        stdout.write_all(line)?;
    }

    Ok(())
}
