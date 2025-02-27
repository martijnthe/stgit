// SPDX-License-Identifier: GPL-2.0-only

//! `stg patches` implementation.

use std::{
    io::Write,
    path::{Path, PathBuf},
};

use anyhow::{anyhow, Context, Result};
use bstr::ByteSlice;
use clap::{Arg, ArgMatches, ValueHint};

use crate::{
    argset,
    ext::{CommitExtended, RepositoryExtended},
    stack::{Error, Stack, StackAccess, StackStateAccess},
    stupid::Stupid,
};

pub(super) const STGIT_COMMAND: super::StGitCommand = super::StGitCommand {
    name: "patches",
    category: super::CommandCategory::StackInspection,
    make,
    run,
};

fn make() -> clap::Command {
    clap::Command::new(STGIT_COMMAND.name)
        .about("Show patches that modify files")
        .long_about(
            "Show the applied patches modifying the given paths. Without path \
             arguments, the files modified in the working tree are used as the \
             paths.",
        )
        .arg(
            Arg::new("pathspecs")
                .help("Show patches that modify these paths")
                .value_name("path")
                .num_args(1..)
                .value_parser(clap::value_parser!(PathBuf))
                .value_hint(ValueHint::AnyPath),
        )
        .arg(argset::branch_arg())
        .arg(
            Arg::new("diff")
                .long("diff")
                .short('d')
                .help("Show the diff for the given paths")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(argset::diff_opts_arg())
}

fn run(matches: &ArgMatches) -> Result<()> {
    let repo = git_repository::Repository::open()?;
    let stack = Stack::from_branch(
        &repo,
        argset::get_one_str(matches, "branch"),
        crate::stack::InitializationPolicy::AllowUninitialized,
    )?;
    let diff_flag = matches.get_flag("diff");

    if stack.applied().is_empty() {
        return Err(Error::NoAppliedPatches.into());
    }

    let stupid = repo.stupid();

    let pathsbuf;
    let pathspecs: Vec<&Path> = if let Some(pathspecs) = matches.get_many::<PathBuf>("pathspecs") {
        pathspecs.map(PathBuf::as_path).collect()
    } else {
        let prefix = if let Some(prefix_result) = repo.prefix() {
            Some(prefix_result.context("determining Git prefix")?)
        } else {
            None
        };

        let mut paths: Vec<&Path> = Vec::new();
        pathsbuf = stupid
            .diff_index_names(
                stack.get_branch_head().tree_id()?.detach(),
                prefix.as_deref(),
            )
            .context("getting modified files")?;

        for path_bytes in pathsbuf.split_str(b"\0") {
            if !path_bytes.is_empty() {
                let path = Path::new(
                    path_bytes
                        .to_os_str()
                        .context("getting modified file list")?,
                );
                paths.push(path);
            }
        }
        paths
    };

    if pathspecs.is_empty() {
        return Err(anyhow!("no local changes and no paths specified"));
    }

    let revs = stupid.rev_list(stack.base().id, stack.top().id, Some(&pathspecs))?;

    if diff_flag {
        // TODO: pager?
        let stdout = std::io::stdout();
        let mut stdout = stdout.lock();
        let diff_opts = argset::get_diff_opts(matches, &repo.config_snapshot(), false, false);
        for patchname in stack.applied() {
            let patch_commit = stack.get_patch_commit(patchname);
            let parent_commit = patch_commit.get_parent_commit()?;
            if revs.contains(&patch_commit.id) {
                write!(
                    stdout,
                    "--------------------------------------------------\n\
                     {patchname}\n\
                     --------------------------------------------------\n"
                )?;
                stdout.write_all(patch_commit.message_raw()?)?;
                write!(stdout, "\n---\n")?;
                let diff = stupid.diff_tree_patch(
                    parent_commit.tree_id()?.detach(),
                    patch_commit.tree_id()?.detach(),
                    Some(&pathspecs),
                    crate::color::use_color(matches),
                    diff_opts.iter(),
                )?;
                stdout.write_all(&diff)?;
            }
        }
    } else {
        for patchname in stack.applied() {
            let patch_commit = stack.get_patch_commit(patchname);
            if revs.contains(&patch_commit.id) {
                println!("{patchname}");
            }
        }
    }

    Ok(())
}
