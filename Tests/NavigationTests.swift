import XCTest

@testable import SparshurPlatform

final class NavigationTests: XCTestCase {
  @MainActor
  func testBackAndForwardTraverseHistoryInOrder() async {
    let model = AppModel()
    XCTAssertFalse(model.canGoBack)
    XCTAssertFalse(model.canGoForward)
    model.destination = .pairPhone
    model.showLesson(.pairing)
    model.goBack()
    XCTAssertEqual(model.destination, .pairPhone)
    XCTAssertTrue(model.canGoBack)
    XCTAssertTrue(model.canGoForward)
    XCTAssertEqual(model.nextDestination, .learn)
    model.goBack()
    XCTAssertEqual(model.destination, .messages)
    XCTAssertFalse(model.canGoBack)
    model.goForward()
    XCTAssertEqual(model.destination, .pairPhone)
    model.goForward()
    XCTAssertEqual(model.destination, .learn)
    XCTAssertFalse(model.canGoForward)
    model.goForward()
    XCTAssertEqual(model.destination, .learn)
  }

  @MainActor
  func testNewNavigationClearsForwardHistory() async {
    let model = AppModel()
    model.showLesson(.pairing)
    model.goBack()
    XCTAssertTrue(model.canGoForward)
    model.destination = .messages
    XCTAssertTrue(model.canGoForward)
    model.destination = .pairPhone
    XCTAssertFalse(model.canGoForward)
    XCTAssertNil(model.nextDestination)
    model.goBack()
    XCTAssertEqual(model.destination, .messages)
    XCTAssertEqual(model.nextDestination, .pairPhone)
  }

  @MainActor
  func testLessonLinkReturnsToMessages() async {
    let model = AppModel()
    XCTAssertFalse(model.canGoBack)
    model.showLesson(.pairing)
    XCTAssertEqual(model.destination, .learn)
    XCTAssertEqual(model.selectedLesson, .pairing)
    XCTAssertEqual(model.previousDestination, .messages)
    model.goBack()
    XCTAssertEqual(model.destination, .messages)
    XCTAssertFalse(model.canGoBack)
  }

  @MainActor
  func testMixedNavigationUnwindsWithoutAddingBackEntries() async {
    let model = AppModel()
    model.destination = .pairPhone
    model.showLesson(.networking)
    model.destination = .messages
    for destination in [Destination.learn, .pairPhone, .messages] {
      model.goBack()
      XCTAssertEqual(model.destination, destination)
    }
    XCTAssertFalse(model.canGoBack)
    model.goBack()
    XCTAssertEqual(model.destination, .messages)
  }

  @MainActor
  func testReselectingScreenDoesNotCreateHistoryOrResetLesson() async {
    let model = AppModel()
    model.destination = .messages
    XCTAssertFalse(model.canGoBack)
    model.showLesson(.pairing)
    model.showLesson(.encryption)
    model.destination = .learn
    model.goBack()
    XCTAssertEqual(model.destination, .messages)
    XCTAssertEqual(model.selectedLesson, .encryption)
    XCTAssertFalse(model.canGoBack)
  }
}
