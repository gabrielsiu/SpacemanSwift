//
//  SpacemanSwiftTests.swift
//  SpacemanSwiftTests
//
//  Created by Gabriel Siu on 2026-11-06.
//

import Foundation
import Testing
@testable import SpacemanSwift

struct SpacemanSwiftTests {

    @Test func parsesOGImageContentAfterProperty() {
        let html = #"<head><meta property="og:image" content="https://featureassets.gocomics.com/assets/abc123?optimizer=image&amp;width=1200"></head>"#
        #expect(ComicService.parseImageURL(fromHTML: html)?.absoluteString
                == "https://featureassets.gocomics.com/assets/abc123?optimizer=image&width=1200")
    }

    @Test func parsesOGImageContentBeforeProperty() {
        let html = #"<meta content="https://example.com/a.jpg" property="og:image"/>"#
        #expect(ComicService.parseImageURL(fromHTML: html)?.absoluteString == "https://example.com/a.jpg")
    }

    @Test func fallsBackToTwitterImage() {
        let html = #"<meta name="twitter:image" content="https://example.com/t.jpg">"#
        #expect(ComicService.parseImageURL(fromHTML: html)?.absoluteString == "https://example.com/t.jpg")
    }

    @Test func returnsNilWhenMissing() {
        #expect(ComicService.parseImageURL(fromHTML: "<html></html>") == nil)
    }

    @Test func buildsPageURL() {
        var c = DateComponents(); c.year = 2024; c.month = 3; c.day = 7
        let date = Calendar.gregorian.date(from: c)!
        #expect(ComicService.pageURL(for: date).absoluteString
                == "https://www.gocomics.com/calvinandhobbes/2024/03/07")
    }
}
