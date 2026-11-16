# Self-hosting the backend on an Ubuntu laptop (free)

This runs the SignBridge backend on a spare Ubuntu / Linux Mint (Cinnamon) laptop
and makes it reachable at **https://api.signbridgeco.xyz**, so the website at
**https://signbridgeco.xyz** (already on Vercel) can log people in, keep history
and recognise personal signs.

```text
Browser / phone ──HTTPS/WSS──▶ Cloudflare (free) ──Tunnel──▶ Ubuntu laptop
                                                              └─ SignBridge backend (127.0.0.1:5000)
                                                                   ├─ Firebase (free Spark plan): login + history
                                                                   └─ /var/lib/signbridge: recordings + models
```

| Piece | Cost | Why |
|---|---|---|
| Ubuntu laptop | Free (electricity) | Enough RAM for MediaPipe, and a real disk so recordings are kept |
| Cloudflare Tunnel | Free | HTTPS + WebSockets with **no router ports opened** and no static IP needed |
| Firebase Spark plan | Free | Login (Email/Password) and the Realtime Database already used by the code |
| Vercel (website) | Free | Already done |

> **Why not PocketBase?** It would mean rewriting login and history in the backend
> and the app. Firebase's free plan already covers this project, so it stays.

---

## 1. Prepare the laptop (5 min)

1. Install updates: `sudo apt update && sudo apt upgrade -y`
2. Stop it from sleeping (Cinnamon: **System Settings → Power Management**):
   - *Suspend when inactive*: **Never** (on AC power)
   - *When the lid is closed*: **Do nothing**
3. Keep it plugged in and on a stable network (cable is best).

## 2. Create the Firebase project (10 min, in a browser)

1. Go to <https://console.firebase.google.com> → **Create a project** → name it `signbridge`
   (Google Analytics: off). Stay on the free **Spark** plan.
2. **Build → Authentication → Get started → Sign-in method → Email/Password → Enable → Save.**
3. **Authentication → Settings → Authorized domains → Add domain:** `signbridgeco.xyz`
4. **Build → Realtime Database → Create database** → pick the closest location → **Start in locked mode**.
   Copy the database URL shown at the top (looks like
   `https://signbridge-xxxx-default-rtdb.asia-southeast1.firebasedatabase.app`).
5. **Project settings (⚙) → General → Your apps → Web (`</>`)** → register an app called
   `signbridge-web` (no hosting). From the config it shows, note `apiKey`, `authDomain` and `projectId`.
6. **Project settings → Service accounts → Generate new private key** → a `.json` file downloads.
   This is a password for your database: never commit it, email it or paste it in chat.

## 3. Install the backend (10–20 min)

On the Ubuntu laptop, plug in the **BUG 2** drive (it mounts at `/media/<you>/BUG 2`) and run:

```bash
sudo apt install -y git
git clone https://github.com/Lukesh2006/signBridge.git ~/signBridge-setup
sudo bash ~/signBridge-setup/backend/deployment/ubuntu/install.sh "/media/$USER/BUG 2/signBridge"
```

This installs the code to `/opt/signbridge`, the Python packages, a `signbridge` service user,
copies the seed sign clips from the USB drive into `/var/lib/signbridge`, and creates
`/etc/signbridge/signbridge.env`. It stops and asks for the Firebase files.

Add the Firebase files:

```bash
# 1) Settings file: copy the example and fill in the values from step 2
sudo cp /opt/signbridge/backend/deployment/ubuntu/firebase.json.example /etc/signbridge/firebase.json
sudo nano /etc/signbridge/firebase.json

# 2) Private key: move the downloaded file (adjust the name)
sudo mv ~/Downloads/signbridge-*-firebase-adminsdk-*.json /etc/signbridge/firebase-admin.json
```

Run the installer again. It starts the service and checks it:

```bash
sudo bash /opt/signbridge/backend/deployment/ubuntu/install.sh
curl http://127.0.0.1:5000/health          # {"status":"ok"}
```

The service starts by itself after every reboot (`systemctl status signbridge-backend`).

## 4. Move the domain's DNS to Cloudflare (10 min + waiting)

A Cloudflare Tunnel needs the domain's DNS on Cloudflare. You already use Cloudflare for
`thisulink.xyz`; this adds `signbridgeco.xyz` next to it without touching thisulink.

1. <https://dash.cloudflare.com> → **Add a domain** → `signbridgeco.xyz` → **Free** plan.
2. Cloudflare copies the existing records. Make sure these two exist and are **DNS only
   (grey cloud)**, because Vercel needs them unproxied:

   | Type | Name | Content | Proxy |
   |---|---|---|---|
   | A | `@` | `76.76.21.21` | DNS only |
   | CNAME | `www` | `cname.vercel-dns.com` | DNS only |

   You can delete `_acme-challenge` and `_domainconnect` (GoDaddy leftovers).
3. Cloudflare shows two nameservers (e.g. `xxx.ns.cloudflare.com`). In **GoDaddy → signbridgeco.xyz →
   DNS → Nameservers → Change → "I'll use my own nameservers"**, enter those two and save.
4. Wait until Cloudflare says the domain is **Active** (minutes to a few hours). The website keeps
   working during the switch because the records are the same.

## 5. Create the Cloudflare Tunnel (10 min)

On the Ubuntu laptop:

```bash
# Install cloudflared from Cloudflare's package repository
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared

# Log in (opens a browser; choose signbridgeco.xyz) and create the tunnel
cloudflared tunnel login
cloudflared tunnel create signbridge          # prints the TUNNEL_ID
cloudflared tunnel route dns signbridge api.signbridgeco.xyz

# Install it as a service
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/<TUNNEL_ID>.json /etc/cloudflared/
sudo cp /opt/signbridge/backend/deployment/ubuntu/cloudflared-config.yml.example /etc/cloudflared/config.yml
sudo nano /etc/cloudflared/config.yml          # replace TUNNEL_ID in both places
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Check from any device:

```bash
curl https://api.signbridgeco.xyz/health       # {"status":"ok"}
```

## 6. Try it

Open **https://signbridgeco.xyz** → register → log in → Personal Signs. The website was built
to use `https://api.signbridgeco.xyz`, so nothing needs rebuilding.

`https://api.signbridgeco.xyz/health/deep` shows `"database":"ok"` once Firebase is connected.
`"model_server":"error"` is expected unless you also run the separate 76-word model server
(set `BASE_URL` in `/etc/signbridge/signbridge.env`). Personal signs work without it.

## Everyday commands

| Task | Command |
|---|---|
| Update to the latest code on GitHub | `sudo bash /opt/signbridge/backend/deployment/ubuntu/install.sh` |
| Backend logs | `sudo journalctl -u signbridge-backend -f` |
| Tunnel logs | `sudo journalctl -u cloudflared -f` |
| Restart backend | `sudo systemctl restart signbridge-backend` |
| Change settings | `sudo nano /etc/signbridge/signbridge.env` then restart |
| Back up recordings | `sudo tar czf signbridge-data.tgz -C /var/lib signbridge` |

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `api.signbridgeco.xyz` shows Cloudflare **502/1033** | Backend or tunnel stopped: check both services' logs above |
| Website says it can't reach the server, browser console shows **CORS** | `ALLOWED_ORIGINS` in `signbridge.env` must contain `https://signbridgeco.xyz` |
| Login fails, logs mention `identitytoolkit` or `API key` | Wrong `apiKey` in `/etc/signbridge/firebase.json`, or Email/Password not enabled |
| `/health/deep` says `"database":"error"` | Wrong `databaseURL`, or `firebase-admin.json` belongs to another project |
| Works, then stops at night | The laptop went to sleep: re-check step 1 |

## Security notes

- The backend listens on `127.0.0.1` only; the tunnel is the only way in. No router ports are opened.
- `/etc/signbridge` is readable only by root and the service; the service can write only to
  `/var/lib/signbridge`.
- If the Firebase private key ever leaks, delete it in **Firebase → Service accounts** and generate a new one.
