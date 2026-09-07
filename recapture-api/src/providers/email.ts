// src/providers/email.ts
import { randomUUID } from 'crypto';
import { env } from '@/config/env';
import type { DispatchResult } from './sms';

/**
 * Email dispatch seam.
 *
 * STUB: no email SDK is wired into this service yet. Replace the body with the
 * real client (e.g. AWS SES / Postmark) — the call site in the OTP service stays
 * the same. The plaintext `code` must never be logged.
 *
 * `OTP_SIMULATE_DISPATCH_FAILURE=true` makes this throw, to exercise the 502
 * rollback path without a real provider.
 */


// // // Here we can use nodemailer to send email using gmail service.
import transport, {
  USER_EMAIL_FOR_NODMAILER,
  isEmailConfigured,
} from '@/utils/nodeMailerTransport';
// const USER_EMAIL_FOR_NODMAILER = process.env.USER_EMAIL_FOR_NODMAILER || "mayasabhaxr@gmail.com";

export async function sendEmail(email: string, code: string): Promise<DispatchResult> {
  if (env.OTP_SIMULATE_DISPATCH_FAILURE) {
    throw new Error('Simulated email dispatch failure');
  }

  // THROWS rather than no-ops. `transport?.sendMail` would swallow a missing
  // configuration into a resolved promise and a stub message id, and the caller
  // would report an OTP as sent that nobody can receive — the failure mode where
  // a user sits waiting for mail and nothing anywhere says why. The OTP service
  // already treats a throw here as a dispatch failure and rolls back.
  if (!isEmailConfigured || !transport) {
    throw new Error(
      'Email is not configured: set USER_EMAIL_FOR_NODMAILER and USER_PASS_FOR_NODMAILER'
    );
  }
  // TODO(provider): await emailClient.send({ to: email, subject, body w/ `code` });
  // void email;
  // void code;
  // return { providerMessageId: `stub-email-${randomUUID()}` };
  // // // Here we can use nodemailer to send email using gmail service.




  const mailOptions = {
    from: USER_EMAIL_FOR_NODMAILER,
    to: email,
    subject: `${code} is Your Access Code.`,
    text: `Your access code is ${code}. This code will expire in 5 minutes. Please do not share it with anyone. For more information, visit our website: https://mayasabhaxr.com`,
    // html: generateHtmlTemplate2(otp, "Mayasabhaxr"),
  }

  // console.log("Sending OTP to email:", email)


  // console.log({
  //   USER_EMAIL_FOR_NODMAILER,
  //   email,
  //   code,
  //   // transport
  // })




  // const info = await transport?.sendMail(mailOptions  );

  const info = await transport.sendMail(mailOptions)
  

  console.log('Email sent: ' + info.response);

  // res.send({ message: 'OTP sent successfully' });
  // return { result: true, message: "OTP sent successfully" }


  // return { providerMessageId: `stub-email-${randomUUID()}` };
  return { providerMessageId: `stub-email-${randomUUID()}` };
}
