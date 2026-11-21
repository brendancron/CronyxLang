const { Plugin, PluginSettingTab, Setting } = require("obsidian");
const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULTS = {
  cxPath: "cx",
  timeoutSeconds: 10,
};

// An app launched from a desktop entry does not inherit the login shell's
// PATH, so a bare `cx` is not found unless these are added.
const EXTRA_PATH = [
  path.join(os.homedir(), ".cronyx", "bin"),
  path.join(os.homedir(), ".local", "bin"),
  "/home/linuxbrew/.linuxbrew/bin",
  "/opt/homebrew/bin",
  "/usr/local/bin",
];

function runCronyx(source, settings) {
  return new Promise((resolve) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cronyx-obsidian-"));
    const file = path.join(dir, "block.cx");
    fs.writeFileSync(file, source);
    const env = {
      ...process.env,
      PATH: [process.env.PATH, ...EXTRA_PATH].filter(Boolean).join(path.delimiter),
    };
    const started = Date.now();
    execFile(
      settings.cxPath,
      ["run", "block.cx"],
      { cwd: dir, env, timeout: settings.timeoutSeconds * 1000, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout, stderr) => {
        fs.rmSync(dir, { recursive: true, force: true });
        let code = 0;
        let note = null;
        if (error) {
          if (error.code === "ENOENT") note = `could not find \`${settings.cxPath}\`; set its path in the plugin settings`;
          else if (error.killed) note = `killed after ${settings.timeoutSeconds}s`;
          code = typeof error.code === "number" ? error.code : null;
        }
        resolve({ stdout, stderr, code, note, ms: Date.now() - started });
      }
    );
  });
}

class CronyxRunner extends Plugin {
  async onload() {
    this.settings = { ...DEFAULTS, ...(await this.loadData()) };
    // Obsidian re-renders a block on every edit elsewhere in the note, so
    // without this each keystroke would wipe the output of every block run.
    this.cache = new Map();
    this.addSettingTab(new CronyxSettings(this.app, this));
    this.registerMarkdownCodeBlockProcessor("cronyx", (source, el) => this.render(source, el));
    this.registerMarkdownCodeBlockProcessor("cx", (source, el) => this.render(source, el));
  }

  render(source, el) {
    el.addClass("cronyx-block");
    el.createEl("pre", { cls: "language-cronyx" }).createEl("code", { text: source });

    const bar = el.createDiv({ cls: "cronyx-bar" });
    const button = bar.createEl("button", { text: "Run" });
    const status = bar.createSpan({ cls: "cronyx-status" });
    const output = el.createDiv({ cls: "cronyx-output" });

    const run = async (fresh) => {
      let pending = fresh ? null : this.cache.get(source);
      if (!pending) {
        pending = runCronyx(source, this.settings);
        this.cache.set(source, pending);
      }
      button.disabled = true;
      status.setText("running…");
      const result = await pending;
      button.disabled = false;
      this.show(result, status, output);
    };

    button.addEventListener("click", () => run(true));
    if (this.cache.has(source)) run(false);
  }

  show(result, status, output) {
    output.empty();
    const failed = result.code !== 0 || result.note;
    status.setText(
      result.note ??
        (result.code === 0 ? `ok · ${result.ms} ms` : `exit ${result.code} · ${result.ms} ms`)
    );
    status.toggleClass("cronyx-failed", !!failed);
    if (result.stdout) output.createEl("pre", { cls: "cronyx-stdout", text: result.stdout });
    if (result.stderr) output.createEl("pre", { cls: "cronyx-stderr", text: result.stderr });
    if (!result.stdout && !result.stderr && !failed) {
      output.createEl("pre", { cls: "cronyx-empty", text: "(no output)" });
    }
  }

  onunload() {
    this.cache.clear();
  }
}

class CronyxSettings extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl } = this;
    const save = () => this.plugin.saveData(this.plugin.settings);
    containerEl.empty();

    new Setting(containerEl)
      .setName("cx executable")
      .setDesc("A name on PATH, or an absolute path.")
      .addText((t) =>
        t.setValue(this.plugin.settings.cxPath).onChange((v) => {
          this.plugin.settings.cxPath = v.trim() || DEFAULTS.cxPath;
          this.plugin.cache.clear();
          save();
        })
      );

    new Setting(containerEl)
      .setName("Timeout (seconds)")
      .addText((t) =>
        t.setValue(String(this.plugin.settings.timeoutSeconds)).onChange((v) => {
          const n = Number(v);
          if (n > 0) {
            this.plugin.settings.timeoutSeconds = n;
            save();
          }
        })
      );
  }
}

module.exports = CronyxRunner;
module.exports.runCronyx = runCronyx;
