import XCTest
@testable import Host

final class MCPHTTPClientRecipesTests: XCTestCase {
    func testBearerRecipesUseAPlaceholderAndNeverContainTheToken() {
        let recipes = MCPHTTPClientRecipes(
            endpoint: "http://127.0.0.1:5254/mcp")
        let secret = "this-is-a-real-secret-that-must-not-render"

        for recipe in recipes.bearer {
            XCTAssertTrue(recipe.configuration.contains(
                "NOW_MCP_BEARER_TOKEN"), recipe.configuration)
            XCTAssertFalse(recipe.configuration.contains(secret))
            XCTAssertTrue(recipe.configuration.contains(recipes.endpoint))
        }
    }

    func testOAuthRecipesContainURLButNoBearerPlaceholder() {
        let recipes = MCPHTTPClientRecipes(
            endpoint: "http://127.0.0.1:5254/mcp")

        for recipe in recipes.oauth {
            XCTAssertTrue(recipe.configuration.contains(recipes.endpoint))
            XCTAssertFalse(recipe.configuration.contains("Bearer"))
            XCTAssertFalse(recipe.configuration.contains(
                "NOW_MCP_BEARER_TOKEN"))
        }
    }

    func testRecipesMatchEachClientsLoopbackAuthSupport() {
        let recipes = MCPHTTPClientRecipes(
            endpoint: "http://127.0.0.1:5254/mcp")
        XCTAssertEqual(Set(recipes.bearer.map(\.client)),
                       Set(["Codex", "Claude Code", "Agentis"]))
        XCTAssertEqual(Set(recipes.oauth.map(\.client)),
                       Set(["Codex", "Claude Code"]))
        XCTAssertEqual(Set(recipes.unauthenticated.map(\.client)),
                       Set(["Codex", "Claude Code", "Agentis"]))
        XCTAssertTrue(recipes.unauthenticated.allSatisfy {
            !$0.configuration.contains("Bearer")
                && !$0.configuration.contains("NOW_MCP_BEARER_TOKEN")
        })
    }

    func testClaudeBearerRecipePersistsEnvironmentExpansionInMCPJSON()
        throws {
        let recipes = MCPHTTPClientRecipes(
            endpoint: "http://127.0.0.1:5254/mcp")
        let recipe = try XCTUnwrap(recipes.bearer.first {
            $0.client == "Claude Code"
        })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(recipe.configuration.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let now = try XCTUnwrap(servers["now"] as? [String: Any])
        let headers = try XCTUnwrap(now["headers"] as? [String: String])

        XCTAssertEqual(now["type"] as? String, "http")
        XCTAssertEqual(headers["Authorization"],
                       "Bearer ${NOW_MCP_BEARER_TOKEN}")
    }
}
