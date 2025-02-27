// SPDX-License-Identifier: GPL-2.0-only

//! Add trailers to a commit message.

use anyhow::{anyhow, Result};
use bstr::ByteSlice;
use clap::ArgMatches;

use crate::{stupid::Stupid, wrap::Message};

/// Add trailers to commit message based on user-provided command line options.
///
/// The `matches` provided to this function must be from a [`clap::Command`] that was
/// setup with [`super::add_args`].
pub(crate) fn add_trailers<'a, 'b>(
    repo: &git_repository::Repository,
    message: Message<'a>,
    matches: &ArgMatches,
    signature: impl Into<git_repository::actor::SignatureRef<'b>>,
    autosign: Option<&str>,
) -> Result<Message<'a>> {
    let signature = signature.into();
    let mut trailers: Vec<(usize, &str, &str)> = vec![];

    for (opt_name, old_by_opt, trailer) in &[
        ("signoff", "sign-by", "Signed-off-by"),
        ("ack", "ack-by", "Acked-by"),
        ("review", "review-by", "Reviewed-by"),
    ] {
        let indices_iter = matches
            .indices_of(opt_name)
            .unwrap_or_default()
            .chain(matches.indices_of(old_by_opt).unwrap_or_default());

        let values_iter = matches
            .get_many::<String>(opt_name)
            .unwrap_or_default()
            .chain(matches.get_many::<String>(old_by_opt).unwrap_or_default());

        for (index, value) in indices_iter.zip(values_iter) {
            trailers.push((index, trailer, value));
        }
    }

    if trailers.is_empty() && autosign.is_none() {
        Ok(message)
    } else {
        let default_value =
            if let (Ok(name), Ok(email)) = (signature.name.to_str(), signature.email.to_str()) {
                format!("{name} <{email}>")
            } else {
                return Err(anyhow!("trailer requires UTF-8 signature"));
            };

        if let Some(autosign) = autosign {
            trailers.push((0, autosign, &default_value));
        }

        trailers.sort_by_key(|(index, _, _)| *index);

        let message_str = message.decode()?;
        let message_bytes = repo.stupid().interpret_trailers(
            message_str.as_bytes(),
            trailers.iter().map(|(_index, trailer, value)| {
                if value.is_empty() {
                    (*trailer, default_value.as_str())
                } else {
                    (*trailer, *value)
                }
            }),
        )?;
        let message = String::from_utf8(message_bytes)
            .map_err(|_| anyhow!("could not decode message after adding trailers"))?;
        Ok(Message::from(message))
    }
}

#[cfg(test)]
mod test {
    use clap::Arg;

    #[test]
    fn val_ind_occ() {
        let m = clap::Command::new("myapp")
            .arg(
                Arg::new("sign-off")
                    .long("sign-off")
                    .num_args(0..=1)
                    .default_missing_value("")
                    .require_equals(true)
                    .action(clap::ArgAction::Append),
            )
            .arg(
                Arg::new("ack")
                    .long("ack")
                    .num_args(0..=1)
                    .default_missing_value("")
                    .require_equals(true)
                    .action(clap::ArgAction::Append),
            )
            .arg(Arg::new("opt").short('o').action(clap::ArgAction::Count))
            .get_matches_from(vec![
                "myapp",          // 0
                "-o",             // 1
                "--sign-off=AAA", // 2 3
                "--ack",          // 4 5 <- phantom index for default value
                "--sign-off",     // 6 7
                "-o",             // 8
                "--ack=BBB",      // 9 10
                "--sign-off=CCC", // 11 12
            ]);
        let sign_off_values = m.get_many::<String>("sign-off").unwrap();
        let sign_off_indices = m.indices_of("sign-off").unwrap();
        let ack_values = m.get_many::<String>("ack").unwrap();
        let ack_indices = m.indices_of("ack").unwrap();

        assert_eq!(3, sign_off_values.len());
        assert_eq!(3, sign_off_indices.len());
        assert_eq!(vec![3, 7, 12], sign_off_indices.collect::<Vec<_>>());
        assert_eq!(vec!["AAA", "", "CCC"], sign_off_values.collect::<Vec<_>>());

        assert_eq!(2, ack_values.len());
        assert_eq!(2, ack_indices.len());
        assert_eq!(vec![5, 10], ack_indices.collect::<Vec<_>>());
        assert_eq!(vec!["", "BBB"], ack_values.collect::<Vec<_>>());
    }
}
