import axios, { type AxiosResponse } from 'axios';

interface HealthResponse { ok: boolean; }

async function ping(): Promise<HealthResponse> {
    try {

        const backendUrl = process.env.backedendMakeAliveUrl || 'https://recapture-apis-dev.onrender.com/health';
        // console.log(backendUrl)

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
    try {

        const min = 1000 * 60 * 10;  // 10 mins
        // const health = await ping();
        await setInterval(ping, min); // ping every 10 seconds
        // console.log('✅ Backend health check passed');
    } catch (err) {
        console.error('❌ Backend health check failed:', err);
    }

}