// SPDX-License-Identifier: GPL-2.0-only

//! `stg reset` implementation.

use anyhow::{anyhow, Result};
use clap::Arg;

use crate::{
    color::get_color_stdout,
    ext::RepositoryExtended,
    patch::patchrange,
    stack::{InitializationPolicy, Stack, StackState},
    stupid::Stupid,
};

pub(super) const STGIT_COMMAND: super::StGitCommand = super::StGitCommand {
    name: "reset",
    category: super::CommandCategory::StackManipulation,
    make,
    run,
};

fn make() -> clap::Command {
    clap::Command::new(STGIT_COMMAND.name)
        .about("Reset the patch stack to an earlier state")
        .long_about(
            "Reset the patch stack to an earlier state. If no state is specified, reset \
             only the changes in the worktree.\n\
             \n\
             The state is specified with a commit id from the stack log, which may be \
             viewed with 'stg log'. Patch name arguments may optionally be provided to \
             limit which patches are reset.",
        )
        .override_usage(
            "stg reset [--hard] [<committish> [<patchname>...]]\n       \
             stg reset --hard",
        )
        .trailing_var_arg(true)
        .arg(
            Arg::new("committish")
                .help("Stack state committish")
                .required_unless_present("hard"),
        )
        .arg(
            Arg::new("patchranges-all")
                .help("Only reset these patches")
                .value_name("patch")
                .num_args(1..)
                .value_parser(clap::value_parser!(patchrange::Specification)),
        )
        .arg(
            Arg::new("hard")
                .long("hard")
                .help("Discard changes in the index and worktree")
                .action(clap::ArgAction::SetTrue),
        )
}

fn run(matches: &clap::ArgMatches) -> Result<()> {
    let repo = git_repository::Repository::open()?;
    if let Some(committish) = crate::argset::get_one_str(matches, "committish") {
        let stack = Stack::from_branch(&repo, None, InitializationPolicy::RequireInitialized)?;
        let commit_id = repo
            .rev_parse_single(committish)
            .map_err(|_| anyhow!("invalid committish `{committish}`"))?
            .object()?
            .try_into_commit()
            .map_err(|_| anyhow!("target `{committish}` is not a commit"))?
            .id;
        stack
            .setup_transaction()
            .use_index_and_worktree(true)
            .discard_changes(matches.get_flag("hard"))
            .allow_bad_head(
                matches
                    .get_many::<patchrange::Specification>("patchranges-all")
                    .is_none(),
            )
            .with_output_stream(get_color_stdout(matches))
            .transact(|trans| {
                let commit = trans.repo().find_commit(commit_id)?;
                let reset_state = StackState::from_commit(trans.repo(), &commit)?;
                if let Some(range_specs) =
                    matches.get_many::<patchrange::Specification>("patchranges-all")
                {
                    let patchnames = patchrange::patches_from_specs(
                        range_specs,
                        &reset_state,
                        patchrange::Allow::All,
                    )?;
                    trans.reset_to_state_partially(&reset_state, &patchnames)
                } else {
                    trans.reset_to_state(reset_state)
                }
            })
            .execute("reset")?;
        Ok(())
    } else if matches.get_flag("hard") {
        let head_tree_id = repo.head_commit()?.tree_id()?.detach();
        repo.stupid().read_tree_checkout_hard(head_tree_id)
    } else {
        unreachable!();
    }
}
