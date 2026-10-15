# Walkie Talkie: keyboard and mouse controls

These controls describe Morgan’s Codex fork. Use the [workflow and feature guide](CODEX_TEST_GUIDE.md) for daily tasks and the [feature/evidence matrix](CODEX_PARITY.md) for implemented features, verification and limitations. Global controls require the existing macOS Accessibility grant; screenshots and film also require Screen Recording. The current build's grant renewal and physical shortcut verification are recorded in the feature matrix.

## Ways to use gestures

| Input | Available now? | How it works |
|---|---|---|
| Keyboard plus trackpad or ordinary mouse | Yes | Press the shortcuts below directly; move the pointer normally to choose screenshot context. The **⌃⌘letter** shortcuts work in both mouse modes. No Logitech hardware or Options+ is needed. Only the legacy ⌃⌥⌘F-key chords depend on Logi mode. |
| Hold a keyboard key, move the pointer in a direction, then release | No | There is no keyboard modifier for a directional gesture or for the wheel-drag crop. Implementing this would require a new gesture mode. |
| Trackpad swipes, such as three-finger left/up/right/down | No built-in support | The app does not recognize macOS trackpad swipes as these actions. |
| Logitech thumb button held while moving the mouse | Yes, with setup | Logi Options+ recognizes the direction and sends the mapped shortcut. Walkie Talkie receives that shortcut; **Logi** mode itself does not recognize pointer directions. |
| Pressable mouse scroll wheel | Yes | **Wheel** mode provides its own click/hold/drag controls. Region capture and drag-to-describe a move need that physical button. |

Keyboard actions therefore cover prompting, dictation, Quick Ask, screenshots,
film, chat switching and notes. Region cropping/moving has no equivalent using
only a keyboard and trackpad. Physical mouse gestures remain untested on this Mac.

## Your trackpad and keyboard

Press **⌃⇧⌘B from any app** for the project/chat switcher. Choose a project, then an open or historical chat. Projects are ordered by their most recent chat. Once bound to Codex desktop, **⌃⌘B** opens it too. In Terminal, ⌃⌘B binds the active Codex CLI tab directly. The menu's **Bind Codex chat…** opens the same switcher.

New CLI chats default to `~/workspace`. Set another default in **Walkie Talkie menu → New chat folder → Choose folder…**, or reset it with **Use ~/workspace**. Picking a folder during a new-chat recording overrides the default for that take.

See [Daily workflows](CODEX_TEST_GUIDE.md#daily-workflows) for existing chats, editing an unsent draft, new chats in the same/different folder, and native desktop chats outside sidebar projects.

| Action | Preferred keyboard shortcut |
|---|---|
| Open the project/chat switcher from any app | **⌃⇧⌘B** |
| Bind the foreground CLI tab / switch a desktop binding | **⌃⌘B** |
| Start / stop a prompt for the bound chat | **⌃⌘D** |
| Start / stop plain dictation without Return | **⌃⌘I** (I for insert); **F5** also remains available |
| Prompt at the caret / stop it | **⌃⌘P** |
| Quick Ask while idle; cancel active work otherwise | **⌃⌘A** (A for ask); stop the question with **⌃⌘I** |
| New CLI chat / redirect the current recording to a new chat | **⌃⌘N**; ignore the folder menu to use the saved default |
| Screenshot during a prompt | **⌃⌘S** |
| Start / stop film during a prompt | **⌃⌘V** (V for video) |
| Typed note during a prompt; disconnect while idle | **⌃⌘T**; during plain dictation it stops without Return |
| Start a bound prompt / switch bound ⇄ caret while recording | **⌃⌘R** (R for route) |
| Toggle the finish-and-close/archive cue | **⌃⌘K** (the existing kamikaze action) |
| Cancel recording, held prompt or running quick answer | **⌃⌘Esc**; while idle it does nothing |
| Plain dictation: start, or stop and insert Return | **⌃⌘E**; during a normal prompt it is another screenshot control |
| Type a Return into the foreground app | **⌃⌘Return**; the existing rear-left action |
| Send / cancel a held prompt | Bare **Return / Escape** |
| Transcribe locally now | **⌃⌘X** |
| Pick a browser element during a prompt | Hold **⌘⇧** until outlined, then click; extension required |

**⌃ is Control; ⌘ is Command.** The new letter shortcuts do not require Fn or
Logi mode. They follow the current keyboard layout; **⌃⌘Q remains macOS Lock
Screen**. Extra Shift/Option combinations are not claimed by the new aliases.
The old function-key controls still work in Logi mode, with Fn when needed.

### Recording reminders

The default bottom-corner reminder is now a compact **Keyboard shortcuts**
list, with the action and its actual shortcut together. During a prompt it
shows End, Screenshot, Film, New chat, Typed note, Switch bound/caret, Close
when done and Cancel. Film and close-cue labels update with their state.
Plain dictation offers Stop/insert, Stop + Return and Cancel; Quick Ask offers
Stop/ask and Cancel. These are reminders, not clickable controls.

Choose **Gestures → Recording hints: Keyboard shortcuts** to restore this
view, or **Recording hints: Mouse gestures** for the original two crosses.
The keyboard reminder appears in either mouse mode; the original mouse legend
is Logi-only. Both hide during right-Command/right-Option hold-to-dictate and
get out of the pointer's way. A wheel-region selection retains its physical
mouse instructions. **Gestures → Keyboard shortcuts** lists every alias.

### Quick Ask without a folder or binding

When nothing is recording, transcribing or held for review, press **⌃⌘A**,
say the question, then press **⌃⌘I** to stop. The answer appears in the reply
bubble without Return, a folder choice or a chat binding. It first answers,
then checks the web, then reviews the answer. **×** or **⌃⌘Esc** stops the
remaining work. A during an active recording/prompt or answer cancels that
work rather than opening another question. The old **⌃⌥⌘F11 → F5** flow also
remains available. Quick Ask is separate from a saved project conversation.

For plain dictation with Local selected, **double-tap right Option** as an
alternative to ⌃⌘I/F5. Or hold **right Command + right Option**, speak, then
release to insert plain text at the caret. These modifier controls do not
turn pointer movement into directional gestures.

The screenshot captures the **display containing the pointer**, with the pointer location passed as context. It does not crop automatically around the pointer. Point at the relevant item before pressing the shortcut. Check that the screenshot count or thumbnail appears before stopping; a flash alone does not prove capture succeeded.

Plain dictation inserts text at the caret and accepts no attachments. Prompt-at-caret carries context; verified Codex CLI prompts submit directly by stable chat ID with actual images, and generic fields receive paste without Return. Use ⌃⌘D for a Codex prompt with screenshots. Keep the selected target visible in Walkie Talkie’s overlay when switching destinations.

For the English test, choose **Engine → Local language → English** before recording. This affects both local captions and the final transcript; no model reload is needed. **Automatic** remains the default, and **French** is also available. This is recognition language, not a translation command.

Try a short prompt: open example.com, point at its heading, press ⌃⌘D, say “What is the heading I’m pointing at?”, press ⌃⌘S, then ⌃⌘D. Review the transcript and screenshot, then Return to send. Use the disposable integration-test chat.

## The icons at the bottom right while recording

If you select **Recording hints: Mouse gestures**, these are a **gesture legend, not clickable buttons**. The default keyboard reminder is described above. The upper cross is the
front thumb button; the lower cross is the rear thumb button. A cross's centre
means click, and its arms mean hold that button, move the mouse in that
direction, then release. Empty boxes mean no action at this stage. The legend
changes between prompts, plain dictation, Quick Ask and a region selection.
It deliberately fades or moves away when the pointer approaches it.

During a normal prompt, these are the actions:

| Icon | Mouse gesture | Keyboard equivalent |
|---|---|---|
| 🏁 end | Front click | **⌃⌘D** to stop; review, then Return to send |
| 🗑️ cancel | Front + left | **⌃⌘Esc** |
| ✨ new | Front + up | **⌃⌘N**; redirects this recording to a new CLI chat |
| ☠️ | Front + down | **⌃⌘K**; toggles the completion-and-close/archive cue |
| 📸 shot | Rear click | **⌃⌘S**, or **⌃⌥⌘F6** |
| 🔴 / ⏹️ video | Rear + up | **⌃⌘V** |
| ⌨️ type | Rear + down | **⌃⌘T**; adds a typed note |

The ☠️ cue asks the receiving agent to finish the task and then close its
verified CLI window or archive the receiving desktop chat. While plain
dictation is recording, rear click instead stops and inserts Return, and
rear + right stops without Return. During Quick Ask those stop gestures ask
the model. See the full mapping below for state-dependent behavior.

## Showing something while you speak

Moving the pointer by itself is **not a continuous visual feed to Codex**.
A normal prompt to the bound chat, a new CLI chat, or a full prompt at the caret
attempts an opening screenshot with that moment's pointer position. Plain F5
dictation and Quick Ask take no opening screenshot. Check the attachment count;
Screen Recording permission is needed for a successful capture.

To point at something later, put the pointer on it and press **⌃⌘S**. That
snapshot carries the pointer coordinates, so say “this button” as you capture
it. Moving somewhere else afterward does not update that snapshot. The shutter
captures the display, not an automatic tight crop around the pointer.

You can also provide context without an explicit shutter:

- Select text during a normal prompt: supported apps' changed selections are
  collected through Accessibility. Plain F5 dictation does not add them.
- In Edge/Chrome with the Inspector extension enabled, hold **⌘⇧** until the
  element outline appears, then click. It adds the picked element's text,
  selector and URL. This is a deliberate pick, not passive hovering.
- A physical wheel drag frames a region; locking it with right-click and then
  drawing a second region describes “move this here”. Film captures a sequence
  of images while it runs rather than continuously streaming the screen.

The inspected fork has rectangle/region and source/destination tools, but no
general freehand arrow drawing tool. An arrow drawn during Victor's demo cannot
be attributed to this fork without identifying the tool or revision he used.

## If you add a Logitech mouse

The **front side button** is the thumb button closer to the nose of the mouse; the **rear side button** is closer to your wrist. “Right/up/left/down” means **hold that button, move the whole mouse a little in that direction, then release**. It does not mean scrolling or moving fingers on the trackpad.

Configure both buttons once in Logi Options+: select the mouse, open **Buttons**, select a side button, choose **Gestures → Custom**, and assign each direction and Click a **Keyboard Shortcut** from this table. Apply the profile where you will use dictation, including your browser/editor; a profile confined to Codex will not apply while the browser is in front. Select **Gestures → Logi** in Walkie Talkie. See [Logitech’s official setup guide](https://hub.sync.logitech.com/options/post/programming-buttons-and-keys-in-options-ntwM6VsAEKhHACY).

Every shortcut below uses **Control + Option + Command**, plus the listed F key.

| Button / gesture | F key | Behavior |
|---|---|---|
| Front: click | F7 | At rest, start a prompt at the caret; during recording, stop it |
| Front: hold + move right | F10 | At rest, start a prompt for the bound chat; during recording, switch between bound chat and caret |
| Front: hold + move left | F11 | While idle, start Quick Ask; during a recording/held prompt, cancel it; during an answer still running, cancel that answer |
| Front: hold + move up | F8 | Prompt to a new CLI session; during recording, convert to that destination |
| Front: hold + move down | F9 | Toggle the kamikaze completion cue |
| Rear: click | F6 | During a prompt, take a screenshot; at rest, start plain dictation; during plain dictation, stop and insert words followed by Return |
| Rear: hold + move right | F5 | Start / stop plain dictation, without Return |
| Rear: hold + move left | F3 | Type Return |
| Rear: hold + move up | F4 | Start / stop screen film during a prompt |
| Rear: hold + move down | F12 | During a local prompt, open typed notes; during plain dictation, stop without Return; otherwise disconnect |

To bind a focused Terminal session, **hold left-click, then press the front thumb button**. Hold left-click and make the front-right gesture to bind and start dictating together. Hovering alone does not change the binding. The keyboard shortcut's desktop-switcher behavior does not change these direct mouse bindings.

For a prompt to the bound chat: **front + right → speak → rear click for screenshots → front click to stop → review → Return**. Repeating front + right during recording changes the destination, so check the overlay.

During a prompt, **press and hold the scroll wheel, drag a rectangle, then release** for a region capture. Command moves the box; Option draws from its centre; Escape cancels. Right-click while dragging locks the source box; release the wheel, then wheel-drag a destination to describe a move. The wheel crop needs a physical pressable wheel. A normal trackpad has no equivalent built into this version.

## Any mouse with a pressable wheel

Choose **Gestures → Wheel** once. Hold left-click and press the wheel to bind the focused Terminal session; hold right-click and press the wheel to disconnect. A wheel click alone starts/stops a prompt; holding it for two seconds during recording cancels. A wheel drag during a prompt captures a region. This mode takes over middle-click while Walkie Talkie is running, so it changes the usual middle-click behavior in browsers/editors. The richer side-button directions above still need their Options+ mappings.

## Current test status

Real keyboard voice, English captions/transcript, screenshot and film delivery
passed in the selected disposable Codex chat. In Edge, the user confirmed the
⌘⇧ picker outline and click, and the app logged the blue box selector. The local
fixture's tone paused on prompt start and resumed after cancellation. Film
contact sheets and synthetic text selections reached Codex and were described
correctly. Physical mouse gestures remain untested.

The automatic question reply also passed: Codex invoked `walkie-reply` and the
user saw the bubble. It stays open until **× at its top right**; there is no
automatic timeout. Further replies queue. Allow the helper's localhost access
when Codex requests it. If delivery is unknown or times out, check the bubble
before retrying.
