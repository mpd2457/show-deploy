# Crew Guide — Show File Delivery

For anyone running the show who isn't setting the kit up. No technical knowledge needed.

If you just need to get a file onto a show machine, this page is all you need. The setup instructions in the [main README](README.md) are for whoever prepares the kit, not for you.

---

## The short version

**One folder. Drop the file in. Check it arrived. Done.**

Everything else on this page is detail for when something goes wrong.

---

## Your job

Put the show files into the **Ingest** folder on the **Ingest laptop**. The kit does the rest — it copies each file to the machines that need it.

The Ingest laptop is the one that gets plugged into the network switch. It's usually the only laptop open on the table.

To find the folder, open the Ingest laptop's desktop and look for **Ingest**. Anything you put in it gets sent automatically within a minute or two.

---

## Which machine gets what

You don't choose. The kit works it out from the file type.

| If the file is... | It goes to... |
|---|---|
| A slide deck or PDF (`.pptx`, `.ppt`, `.key`, `.pdf`) | The three **GFX** machines |
| Video or audio (`.mp4`, `.mov`, `.mxf`, `.avi`, `.mkv`, `.wav`, `.mp3`, `.aac`, `.m4a`) | The two **Mitti** machines |
| Anything else | All of them |

So a new slide deck just goes in Ingest — it'll turn up on all three GFX machines on its own. You don't need to copy it anywhere by hand.

---

## Sending an updated version

**Give each version a new filename.** Adding `_v2` takes a second and removes a whole category of confusion:

| Instead of | Use |
|---|---|
| `opening.pptx` | `opening.pptx`, then `opening_v2.pptx`, then `opening_v3.pptx` |

**Why it matters:** the kit judges "is this the same file?" by name and size. So:

- **Same name, different content, different size** — gets sent again as a new version. This usually just works.
- **Same name, same size, different content** — this is the trap. The kit sees a file it has already handled at that exact size and leaves it alone. You will wait for an update that never comes, and nothing in the log will explain why.

The second case is rare but genuinely confusing when it happens, which is why a fresh filename is the habit worth having. **If you are ever unsure whether an update went out, rename it and drop it again.**

### If a file gave up

The log ends with `GIVE UP` if a machine refused the file every time — usually a wrong password or a share that isn't switched on. To retry:

**Copy the file into Ingest again** (don't just leave it sitting there), or drop it under a new name. Copying it again gives it a new timestamp, which is how the kit knows you mean it this time.

---

## Checking it worked

**The easiest check: go and look at the machine.**

If you dropped a deck, the GFX machines will have a copy in their Ingest folder. If you dropped media, the Mitti machines will have it. Just walk over and look. If it's on the machine, it's there — the kit checks each file after sending it and won't call it done unless the receiving machine confirmed it.

**If you want to watch it happen,** there's a log file in the Ingest folder called `push_log.txt`. You don't need to understand it. You're looking for one word:

```
DONE   opening_v2.pptx
```

`DONE` means every machine that should have it, has it.

Two other words worth knowing. `SKIP` means a machine wasn't turned on or wasn't connected yet — it will keep trying, so no action needed. `FAIL` or `GIVE UP` means something needs a human.

---

## If it doesn't arrive

**Wait a minute.** Big files take time. A 4 GB video will not be there thirty seconds after you drop it.

If it's still not there after a couple of minutes:

1. **Is the machine on?** A powered-off or disconnected machine is skipped, not failed, and gets picked up when it appears. Switch it on, check the cable, and it'll be delivered on its own.
2. **Does the name match what you expect?** See [Sending an updated version](#sending-an-updated-version). Same name and same size is the one case that gets quietly ignored.
3. **Ask someone technical.** Beyond that it's not your problem to solve, and guessing won't help.

---

## Things not to worry about

- **Don't move, rename or delete a file while it's sending.** Opening or previewing one is fine. The kit waits for a file to stop changing before sending, which is what stops a half-copied file going out — so a file you shuffle around mid-send resets that check.
- **Don't re-copy a file that's already on its way.** If it's sending, let it send. Everything sent is also saved to an `Archive` folder on the Ingest laptop, so nothing is lost. (Re-copying *is* the fix for a `GIVE UP`, but that's a different situation — see above.)
- **Don't drag files into the Day folders to speed things up.** Files inside `Day 1` through `Day 5` are left alone on purpose — those are for sorting after delivery. Only files sitting directly in the Ingest folder get sent.
- **Don't worry about a machine being switched off.** That's expected and handled, and it'll catch up on its own.
- **Don't switch off the Ingest laptop during a show.** If you have to, plug it back in — anything that failed resumes where it left off.
- **Wi-Fi is irrelevant.** Everything is wired. Nobody needs to join any network or type any password.

---

## If you need the password

You might be asked for the password for the show machines. It is:

```
showrig
```

The same on all three GFX machines, and the same as the Mac logins. If whoever set up the kit chose something else, ask them rather than guessing — a wrong password makes every push fail and the log will say so.

---

## Who to ask

| Problem | Ask |
|---|---|
| File didn't arrive | Whoever set up the kit |
| Can't find the Ingest folder | Whoever set up the kit |
| Laptop won't connect / no lights | Whoever set up the kit |
| A file is missing but the log says `DONE` | Whoever set up the kit — the log will tell them which machine it's on |
| Mac says "unidentified developer" | Not a fault — right-click the file and choose **Open** |
| A machine asks to restart | Only a GFX machine does this, and only after renaming itself. Let it restart. |
| Setup file won't open at all | Double-click on Windows, right-click → Open on Mac. Pick the one for that machine. |

In a genuine emergency, the log is the fastest way to a straight answer. Screenshot `push_log.txt` and send it.

---

## Starting the setup scripts

**You only need this if you're setting the kit up.** If someone set the rig up
before you got there, skip to the next section — everything else on this page is
about putting files on machines, which is the same all show long.

There are six machines and each one is started a slightly different way, because
Windows, Mac and Linux each put up their own kind of roadblock.

| Which machine | What to click | Then |
|---|---|---|
| **GFX1** (first of the three big laptops) | Double-click `RUN-gfx1.bat` | Click **Yes** when it asks |
| **GFX2** (second) | Double-click `RUN-gfx2.bat` | Click **Yes** when it asks |
| **GFX3** (third) | Double-click `RUN-gfx3.bat` | Click **Yes** when it asks |
| **MITTIA** (first Mac) | Right-click `RUN-mittiA.command` → **Open** | Confirm it |
| **MITTIB** (second Mac) | Right-click `RUN-mittiB.command` → **Open** | Confirm it |
| **INGEST** (the Ingest laptop) | See below | Type your login password |

### The three things that trip people up

**On Windows, just double-click.** Don't right-click for "Run as administrator" —
these files already ask for permission themselves, so a box will pop up on its
own. Click **Yes** on it. You'll see this every time and it's normal.

**On Mac, right-click first.** If you double-click a Mac setup file, macOS
refuses it and says it's "from an unidentified developer". That isn't a fault,
it's just how Mac does first-time approval. **Right-click the file, choose
Open**, and confirm. After that, double-clicking works like normal.

**On Linux, use a terminal.** Open the terminal app, type these two lines, and
press Enter after each:

```
cd ~/Desktop/show-deploy
sudo bash ./setup-ingest.sh
```

It asks for your Mac login password — not the show password, your own one.

### When it asks for the show password

Just **press Enter**. The password is `showrig` and it works on all six machines,
so there's nothing to remember and nothing to type. If you'd rather set your own,
type it instead — but then you have to type that same one on every machine, or
the file transfers will fail.

### Order

Do the five far-end machines first, and **Ingest last**. Ingest is the one that
holds the passwords, and it needs the other machines to already exist before it
can store them.

### If it asks you to restart a machine

**Restart it.** The GFX and Mitti machines both rename themselves during setup,
and that change doesn't fully take effect until they restart. It's a few minutes
each, so do them one at a time while the others carry on being set up.

The **Ingest** laptop never needs restarting — if one of those asks you to
restart, stop and ask someone.

---

## The long version

If something about the machines themselves needs changing, or you want the detail
behind any of this, that's a separate page: the [main README](README.md). It
covers the same ground in more depth, plus the parts that only matter when
something has gone wrong.