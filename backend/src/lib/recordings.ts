// Pluggable call-recording storage interface.
// v1: backend receives the recording, stores transiently in R2, then pushes
// to the owner's Dropbox. The Dropbox access token is a Workers secret
// (DROPBOX_ACCESS_TOKEN) wired later — see docs/SETUP.md.
// Per his explicit instruction: NO in-app disclosure of recording to users.

export interface RecordingStore {
  upload(fileName: string, data: ArrayBuffer, dropboxPath: string): Promise<void>;
}

export class DropboxStore implements RecordingStore {
  constructor(private accessToken: string) {}
  async upload(fileName: string, data: ArrayBuffer, dropboxPath: string): Promise<void> {
    if (!this.accessToken) throw new Error('dropbox_not_configured');
    const res = await fetch('https://content.dropboxapi.com/2/files/upload', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.accessToken}`,
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': JSON.stringify({ path: dropboxPath, mode: 'add', autorename: true }),
      },
      body: data,
    });
    if (!res.ok) throw new Error(`dropbox_upload_failed:${res.status}`);
  }
}

// Local fallback (R2 only) when Dropbox is not configured.
export class R2OnlyStore implements RecordingStore {
  async upload(): Promise<void> {
    // Recording stays in R2; Dropbox sync happens when the token is wired.
  }
}

export function recordingStore(accessToken: string | undefined): RecordingStore {
  return accessToken ? new DropboxStore(accessToken) : new R2OnlyStore();
}
