import Foundation

/// 長い出力をページャへ渡す。**端末に出すときだけ。**
///
/// `git diff` と同じ線。パイプやリダイレクトのときに割り込むと、`grep` や `>` に
/// つないだ人の手元で壊れる ―― 色を端末のときだけ付けるのと、同じ判断。
///
/// 既定は `more`。`MRDIFF_PAGER` で上書きでき、`--no-pager` で切れる。
/// `PAGER` は**見ない** ―― 環境で勝手に別のものが立ち上がると、出力を Issue に
/// 貼った人が「自分の手元と違う」ことになる（`MRDIFF_LANG` と同じ理由）。
///
/// **`Process` ではなく `posix_spawn` を直に使う。**`Process` で起こすと子が
/// 別のプロセスグループに入ることがあり、そうなるとページャが端末から読んだ瞬間に
/// SIGTTIN で止まる ―― 何も描かないまま固まった（実際に踏んだ）。
/// ここでは `POSIX_SPAWN_SETPGROUP` を**付けない**ので、子は同じプロセスグループと
/// 制御端末を引き継ぎ、前面でキー入力を読める。
/// （`popen` は Swift からは呼べない ―― unavailable になっている。）
enum Pager {

    private static var handle: UnsafeMutablePointer<FILE>?
    private static var child: pid_t = -1

    /// 使うページャ。切ってあるか、端末でなければ nil。
    static func command(disabled: Bool) -> String? {
        if disabled { return nil }
        if isatty(fileno(stdout)) != 1 { return nil }
        let name = ProcessInfo.processInfo.environment["MRDIFF_PAGER"] ?? "more"
        // 空文字は「切る」と読む（MRDIFF_PAGER= で無効にできる）
        return name.isEmpty ? nil : name
    }

    /// 起動して書き込み先を返す。**立ち上がらなければ nil**（呼ぶ側が標準出力へ落とす）。
    static func start(_ command: String) -> UnsafeMutablePointer<FILE>? {
        // ページャは端末を直に描く。こちらの stdio に溜めたものが後から出ると
        // 順番が壊れるので、渡す前に必ず吐き出しておく。
        fflush(stdout)

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // 子の標準入力 ＝ パイプの読み口。書き口は子に渡さない
        posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        // 標準出力・標準エラーはそのまま（＝この端末）を引き継ぐ

        let argv = ["/bin/sh", "-c", command]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { for p in cArgv where p != nil { free(p) } }

        // **色を素通りさせる。**less は既定でエスケープを解釈せず、`ESC[31m` が
        // 文字のまま並ぶ。git と同じ `FRX` を渡す。
        //   F = 1 画面に収まるなら、待たずに終わる
        //   R = 色のエスケープはそのまま通す
        //   X = 抜けたあとに画面を消さない（差分が端末に残る）
        //
        // **`LESS` と `MORE` の両方に渡す。**macOS の /usr/bin/more は less への
        // ハードリンクで、**less は起動名で読む変数を変える** ―― more として
        // 呼ばれると `LESS` ではなく `MORE` を見る。`LESS` だけ渡して、色が文字の
        // まま出た（実測で確認）。
        //
        // 既に設定している人のものは上書きしない。
        var envp: [UnsafeMutablePointer<CChar>?] = []
        var hasLESS = false, hasMORE = false
        var e = environ
        while let entry = e.pointee {
            if strncmp(entry, "LESS=", 5) == 0 { hasLESS = true }
            if strncmp(entry, "MORE=", 5) == 0 { hasMORE = true }
            envp.append(strdup(entry))
            e += 1
        }
        if !hasLESS { envp.append(strdup("LESS=FRX")) }
        if !hasMORE { envp.append(strdup("MORE=FRX")) }
        envp.append(nil)
        defer { for p in envp where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, nil, &cArgv, &envp)
        close(readEnd)
        guard rc == 0 else {
            close(writeEnd)
            return nil
        }
        guard let f = fdopen(writeEnd, "w") else {
            close(writeEnd)
            return nil
        }
        handle = f
        child = pid
        return f
    }

    /// 閉じて、ページャが終わるまで待つ。**待たないと、シェルの入力と競り合う。**
    static func finish() {
        if let f = handle {
            fclose(f)      // 書き口を閉じる ＝ ページャに EOF が届く
            handle = nil
        }
        if child > 0 {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            child = -1
        }
    }
}
