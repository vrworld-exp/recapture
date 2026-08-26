import axios, { type AxiosResponse } from 'axios';

interface HealthResponse { ok: boolean; }

async function ping(): Promise<HealthResponse> {
    try {

        const backendUrl = process.env.backedendMakeAliveUrl || 'https://recapture-apis-dev.onrender.com/health';
        // console.log(backendUrl)


        if (!backendUrl.startsWith('http://')) {
            console.log('Backend health check URL is not http://, skipping ping:', backendUrl);
            return { ok: false, message: 'Backend health check URL is not http://, skipping ping' } as HealthResponse;
        }

        const res: AxiosResponse<HealthResponse> = await axios.get(
            backendUrl,
        );

        console.log('Backend health check response on every 10 seconds:', res.data);

        return res.data; // already JSON-parsed; non-2xx throws
    } catch (err) {
        if (axios.isAxiosError(err)) {
            // err.response?.status, err.response?.data, err.code (e.g. 'ECONNABORTED')
            throw new Error(`ping failed: ${err.response?.status ?? err.code}`);
        }
        throw err;
    }
}




export async function axiosBackendMakeAlive(): Promise<void> {
    const min = 1000 * 60 * 10;  // 10 mins

    // The callback MUST NOT be `ping` itself. `ping` rejects on a failed health
    // check, and a rejected promise from a timer callback has nobody to catch
    // it — under Node's default that unhandled rejection kills the API process
    // ten minutes after boot, for a keep-alive ping that nothing depends on.
    // Swallow it here: a missed ping is worth a log line, never an outage.
    const timer = setInterval(() => {
        void ping().catch((err: unknown) => {
            console.error('❌ Backend health check failed:', err);
        });
    }, min);

    // Do not hold the event loop open for a best-effort ping — the API's own
    // listener is what should decide when the process may exit.
    timer.unref();
}