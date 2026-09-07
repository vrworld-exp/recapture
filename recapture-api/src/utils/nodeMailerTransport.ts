// src/utils/nodeMailerTransport.ts
//
// The Gmail SMTP transport that sends OTP mail.
//
// ⚠ CREDENTIALS COME FROM THE ENVIRONMENT ONLY. A literal Gmail address and app
// password used to sit here as `||` fallbacks. They are gone: a fallback
// credential in source is a credential in every clone, every fork, every CI log
// and every screen share — and this one sends real sign-in mail for real users.
//
// Deleting them from HEAD does NOT un-leak them. That password is still in git
// history, so it has to be ROTATED in the Google account; removing it here only
// stops the leak getting wider.
//
// Both vars are declared `sync: false` in render.yaml, so the values are set in
// the Render dashboard and never travel through the repo.
import nodemailer from 'nodemailer';

const USER_EMAIL_FOR_NODMAILER = process.env.USER_EMAIL_FOR_NODMAILER ?? '';
const USER_PASS_FOR_NODMAILER = process.env.USER_PASS_FOR_NODMAILER ?? '';

/** Whether this deployment can actually send mail. */
export const isEmailConfigured =
  USER_EMAIL_FOR_NODMAILER !== '' && USER_PASS_FOR_NODMAILER !== '';

/**
 * NULL when unconfigured, rather than a transport built from empty strings.
 *
 * A transport with blank credentials does not fail at construction — it fails
 * on the first send, inside nodemailer, with an SMTP auth error that says
 * nothing about the missing config. A null here lets the call site say the one
 * useful sentence instead: which two variables to set.
 */
const transport = isEmailConfigured
  ? nodemailer.createTransport({
      service: 'gmail',
      host: 'smtp.gmail.com',
      secure: true,
      port: 465,
      auth: {
        user: USER_EMAIL_FOR_NODMAILER,
        pass: USER_PASS_FOR_NODMAILER,
      },
    })
  : null;

export default transport;
export { USER_EMAIL_FOR_NODMAILER };
