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
        let uri = try XCTUnwrap(environment["MATRIX_ROOM_URI"])
        XCTAssertTrue(uri.hasPrefix("matrix:roomid/"))
        let roomURL = try XCTUnwrap(URL(string: uri))
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
            tap(app.buttons[A11yIdentifiers.authenticationStartScreen.signIn], "Manual sign-in", in: app)
            let server = app.textFields[A11yIdentifiers.changeServerScreen.server]
            XCTAssertTrue(server.waitForExistence(timeout: 25), "Server selection field")
            server.clearAndTypeText(base + "\n", app: app, verifyingValue: false)
            let signIn = app.buttons[A11yIdentifiers.loginScreen.continue]
            XCTAssertTrue(signIn.waitForExistence(timeout: 45), "Password sign-in resolved on the owned server")
            let userField = app.textFields[A11yIdentifiers.loginScreen.emailUsername]
            tap(userField, "Username", in: app)
            userField.typeText(user)
            let passwordField = app.secureTextFields[A11yIdentifiers.loginScreen.password]
            tap(passwordField, "Synthetic password", in: app)
            passwordField.typeText(password)
            tap(signIn, "Submit sign-in", in: app)
            finishFirstRun(in: app)
            openRoom(app, named: room, url: roomURL)
        }

        XCTContext.runActivity(named: "MATRIX_UI exchange live text") { _ in
            expectText(history, in: app)
            sendText(outgoing, in: app)
            expectText(reply, in: app)
        }

        XCTContext.runActivity(named: "MATRIX_UI restart and verify a fresh sync") { _ in
            app.terminate()
            app.launch()
            openRoom(app, named: room, url: roomURL)
            expectText(outgoing, in: app)
            expectText(reply, in: app)
            sendText(restored, in: app)
            expectText(restartReply, in: app)
        }

        XCTContext.runActivity(named: "MATRIX_UI open, save and re-send the peer image") { _ in
            tap(labelled("Image", in: app), "Peer image", in: app)
            downloadPreview(in: app)
            let photosPermission = app.alerts.buttons["Allow"]
            if photosPermission.waitForExistence(timeout: 5), photosPermission.isHittable {
                photosPermission.tap()
            }
            closePreview(in: app)
            openAttachments(in: app)
            tap(app.buttons[A11yIdentifiers.roomScreen.attachmentPickerPhotoLibrary], "Photo library", in: app)
            tap(app.scrollViews.images.firstMatch, "Saved peer photo", in: app, timeout: 25)
            let pickerAdd = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add")).firstMatch
            if pickerAdd.waitForExistence(timeout: 3), pickerAdd.isHittable {
                pickerAdd.tap()
            }
            sendPreview(in: app)
        }

        XCTContext.runActivity(named: "MATRIX_UI open, download and re-send the peer TXT") { _ in
            tap(labelled("File", in: app), "Peer TXT event", in: app, timeout: 45)
            downloadPreview(in: app)
            let localStorage = labelled("On My iPhone", in: app)
            if localStorage.waitForExistence(timeout: 3), localStorage.isHittable {
                localStorage.tap()
            }
            tap(app.buttons["Save"], "Save TXT in Files", in: app)
            closePreview(in: app)

            openAttachments(in: app)
            tap(app.buttons[A11yIdentifiers.roomScreen.attachmentPickerDocuments], "Documents picker", in: app)
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            let file = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
            tap(file, "Exported TXT", in: app, timeout: 30)
            let open = app.buttons["Open"]
            if open.waitForExistence(timeout: 3), open.isHittable {
                open.tap()
            }
            sendPreview(in: app)
        }
    }

    private func tap(_ element: XCUIElement, _ context: String, in app: XCUIApplication, timeout: TimeInterval = 20) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), context)
        if element.isHittable {
            element.tap()
        } else {
            tapVisibleCenter(of: element, context: context, in: app)
        }
    }

    private func tapVisibleCenter(of element: XCUIElement, context: String, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let visible = element.frame.intersection(window.frame)
        XCTContext.runActivity(named: "MATRIX_UI \(context) frame=\(element.frame) visible=\(visible)") { _ in }
        XCTAssertGreaterThan(visible.width, 0, "\(context) is on screen")
        XCTAssertGreaterThan(visible.height, 0, "\(context) is on screen")
        let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let offset = CGVector(dx: visible.midX - window.frame.minX, dy: visible.midY - window.frame.minY)
        origin.withOffset(offset).tap()
    }

    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func openRoom(_ app: XCUIApplication, named room: String, url: URL) {
        let cell = app.buttons[A11yIdentifiers.homeScreen.roomName(room)]
        XCTAssertTrue(cell.waitForExistence(timeout: 65), "Joined fixture room available in the list")
        XCTContext.runActivity(named: "MATRIX_UI open the joined room through its registered Matrix URL") { _ in
            app.open(url)
            XCTAssertTrue(app.buttons[room].waitForExistence(timeout: 35), "Native room header")
            let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer]
            XCTAssertTrue(composer.waitForExistence(timeout: 25), "Native message composer")
        }
    }

    private func finishFirstRun(in app: XCUIApplication) {
        let notificationTitle = "Allow notifications and never miss a message"
        let verifiedTitle = "Device verified"
        let screens = app.staticTexts.matching(NSPredicate(format: "label IN %@", [notificationTitle, verifiedTitle]))
        if screens.firstMatch.waitForExistence(timeout: 45), app.staticTexts[verifiedTitle].exists {
            tap(app.buttons["Continue"], "Acknowledge confirmed device", in: app)
        }
        if app.staticTexts[notificationTitle].waitForExistence(timeout: 15) {
            tap(app.buttons["Not now"], "Choose no notifications for the loopback test", in: app)
            XCTAssertTrue(app.staticTexts[notificationTitle].waitForNonExistence(timeout: 30), "Dismissed notification onboarding")
        }
    }

    private func expectText(_ text: String, in app: XCUIApplication) {
        let timeline = NSPredicate(format: "value CONTAINS %@ AND identifier != %@",
                                   text, A11yIdentifiers.roomScreen.messageComposer)
        let messages = app.textViews.matching(timeline).firstMatch
        XCTAssertTrue(messages.waitForExistence(timeout: 45), "Missing Matrix timeline text: \(text)")
    }

    private func sendText(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer]
        tap(composer, "Message composer", in: app)
        composer.typeText(text)
        XCTAssertEqual(composer.value as? String, text, "The typed text is in the native composer")
        tap(app.buttons[A11yIdentifiers.roomScreen.sendButton], "Send text", in: app)
        expectText(text, in: app)
    }

    private func openAttachments(in app: XCUIApplication) {
        tap(app.buttons[A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions], "Open attachment options", in: app)
    }

    private func closePreview(in app: XCUIApplication) {
        let close = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"])).firstMatch
        tap(close, "Close media preview", in: app)
    }

    private func downloadPreview(in app: XCUIApplication) {
        let details = app.navigationBars.buttons
            .matching(NSPredicate(format: "NOT (label IN %@)", ["Done", "Close", "Back"])).firstMatch
        tap(details, "Media preview details", in: app)
        tap(app.buttons["Download"], "Download the previewed media", in: app, timeout: 30)
    }

    private func sendPreview(in app: XCUIApplication) {
        tap(app.buttons["Send"].firstMatch, "Send selected media", in: app, timeout: 30)
    }
}
