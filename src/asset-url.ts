const ROOT = ((import.meta as unknown as {
    env: {
        BASE_URL: string;
    };
}).env.BASE_URL).replace(/\/$/, '');
export function assetUrl(path: string): string {
    const full = `${ROOT}/assets/native/${path}`;
    const embedded = (window as unknown as {
        __BALL_ASSETS__?: Record<string, string>;
    }).__BALL_ASSETS__;
    return embedded?.[full] || embedded?.[full.replace(/^.*?\/assets\//, 'assets/')] || embedded?.[`/assets/native/${path}`] || full;
}
