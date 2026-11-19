import XCTest

@MainActor
final class MatrixCandidateTests: XCTestCase {
    func testNativeMatrixExchange() throws {
        continueAfterFailure = false
        executionTimeAllowance = 360
        let environment = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(environment["MATRIX_BASE"])
        XCTAssertEqual(base, "http://127.0.0.1:8090")
        let user = try XCTUnwrap(environment["MATRIX_USER"])
        let password = try XCTUnwrap(environment["MATRIX_PASSWORD"])
        let room = try XCTUnwrap(environment["MATRIX_ROOM"])
        let history = try XCTUnwrap(environment["MATRIX_HISTORY"])
        let outgoing = try XCTUnwrap(environment["MATRIX_OUTGOING"])
        let reply = try XCTUnwrap(environment["MATRIX_REPLY"])
        let restored = try XCTUnwrap(environment["MATRIX_RESTORED"])
        let restartReply = try XCTUnwrap(environment["MATRIX_RESTART_REPLY"])
        let filename = try XCTUnwrap(environment["MATRIX_FILE"])

        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        defer { app.terminate() }

        XCTContext.runActivity(named: "MATRIX_UI sign in over the loopback Matrix API") { _ in
            tap(app.buttons[A11yIdentifiers.authenticationStartScreen.signIn], "Manual sign-in")
            let server = app.textFields[A11yIdentifiers.changeServerScreen.server]
            XCTAssertTrue(server.waitForExistence(timeout: 25), "Server selection field")
            server.clearAndTypeText(base + "\n", app: app, verifyingValue: false)
            let signIn = app.buttons[A11yIdentifiers.loginScreen.continue]
            XCTAssertTrue(signIn.waitForExistence(timeout: 45), "Password sign-in resolved on the owned server")
            let userField = app.textFields[A11yIdentifiers.loginScreen.emailUsername]
            tap(userField, "Username")
            userField.typeText(user)
            let passwordField = app.secureTextFields[A11yIdentifiers.loginScreen.password]
            tap(passwordField, "Synthetic password")
            passwordField.typeText(password)
            tap(signIn, "Submit sign-in")
            openRoom(app, named: room)
        }

        XCTContext.runActivity(named: "MATRIX_UI exchange live text") { _ in
            expectText(history, in: app)
            sendText(outgoing, in: app)
            expectText(reply, in: app)
        }

        XCTContext.runActivity(named: "MATRIX_UI restart and verify a fresh sync") { _ in
            app.terminate()
            app.launch()
            openRoom(app, named: room)
            expectText(outgoing, in: app)
            expectText(reply, in: app)
            sendText(restored, in: app)
            expectText(restartReply, in: app)
        }

        XCTContext.runActivity(named: "MATRIX_UI open the peer image and send a synthetic photo") { _ in
            tap(labelled("Image", in: app), "Peer image")
            closePreview(in: app)
            openAttachments(in: app)
            tap(app.buttons[A11yIdentifiers.roomScreen.attachmentPickerPhotoLibrary], "Photo library")
            tap(app.scrollViews.images.firstMatch, "Synthetic photo", timeout: 25)
            let pickerAdd = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add")).firstMatch
            if pickerAdd.waitForExistence(timeout: 3), pickerAdd.isHittable {
                pickerAdd.tap()
            }
            sendPreview(in: app)
        }

        XCTContext.runActivity(named: "MATRIX_UI open, download and re-send the peer TXT") { _ in
            tap(labelled("File", in: app), "Peer TXT event", timeout: 45)
            let details = app.navigationBars.buttons
                .matching(NSPredicate(format: "label IN %@", ["Info", "Details"])).firstMatch
            tap(details, "File preview details")
            tap(app.buttons["Download"], "Download TXT", timeout: 30)
            let localStorage = labelled("On My iPhone", in: app)
            if localStorage.waitForExistence(timeout: 3), localStorage.isHittable {
                localStorage.tap()
            }
            tap(app.buttons["Save"], "Save TXT in Files")
            closePreview(in: app)

            openAttachments(in: app)
            tap(app.buttons[A11yIdentifiers.roomScreen.attachmentPickerDocuments], "Documents picker")
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            let file = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
            tap(file, "Exported TXT", timeout: 30)
            let open = app.buttons["Open"]
            if open.waitForExistence(timeout: 3), open.isHittable {
                open.tap()
            }
            sendPreview(in: app)
        }
    }

    private func tap(_ element: XCUIElement, _ context: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), context)
        XCTAssertTrue(element.isHittable, context)
        element.tap()
    }

    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func openRoom(_ app: XCUIApplication, named room: String) {
        let cell = app.buttons[A11yIdentifiers.homeScreen.roomName(room)]
        tap(cell, "Joined fixture room", timeout: 65)
        XCTAssertTrue(app.buttons[A11yIdentifiers.roomScreen.name].waitForExistence(timeout: 30), "Room header")
    }

    private func expectText(_ text: String, in app: XCUIApplication) {
        let messages = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(messages.waitForExistence(timeout: 45), "Missing Matrix timeline text: \(text)")
    }

    private func sendText(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer]
        tap(composer, "Message composer")
        composer.typeText(text)
        tap(app.buttons[A11yIdentifiers.roomScreen.sendButton], "Send text")
    }

    private func openAttachments(in app: XCUIApplication) {
        tap(app.buttons[A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions], "Open attachment options")
    }

    private func closePreview(in app: XCUIApplication) {
        let close = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"])).firstMatch
        tap(close, "Close media preview")
    }

    private func sendPreview(in app: XCUIApplication) {
        tap(app.buttons["Send"].firstMatch, "Send selected media", timeout: 30)
    }
}
