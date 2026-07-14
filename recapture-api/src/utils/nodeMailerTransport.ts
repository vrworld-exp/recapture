
import nodemailer from "nodemailer";

const USER_EMAIL_FOR_NODMAILER = process.env.USER_EMAIL_FOR_NODMAILER || "mayasabhaxr@gmail.com";
const USER_PASS_FOR_NODMAILER = process.env.USER_PASS_FOR_NODMAILER || "mdxykrvdpwwpcwne";

// console.log({
//     USER_EMAIL_FOR_NODMAILER,
//     USER_PASS_FOR_NODMAILER,
// })


const transport = nodemailer.createTransport({

    service: "gmail",
    host: "smtp.gmail.com",
    secure: true,
    port: 465,
    auth: {
        user: USER_EMAIL_FOR_NODMAILER,
        pass: USER_PASS_FOR_NODMAILER,
    },

})


export default transport;
export { USER_EMAIL_FOR_NODMAILER, };


