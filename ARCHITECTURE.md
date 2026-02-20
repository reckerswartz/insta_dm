# Instagram Application Architecture Guidelines

This document outlines the refactored architecture of the Instagram application, focusing on `Instagram::Client` and `InstagramProfileEvent`, which have been restructured to adhere to SOLID principles and prevent "God Object" anti-patterns.

## Structure and Responsibilities

Our application relies on two primary entities for external interactions and internal event tracking. To maintain scalability, their responsibilities have been isolated into cohesive modules.

### `Instagram::Client` 
Acts as a Facade that coordinates external Instagram interactions. It delegates logic to specialized domains:
- **`Instagram::Client::BrowserAutomation`**: Manages Selenium WebDriver setup, session cookies, local storage management, and authentication states.
- **`Instagram::Client::FeedEngagementService`**: Handles UI scrolling and capturing `capture_home_feed_posts!` as well as `auto_engage_home_feed!` logic.
- **`Instagram::Client::StoryScraperService`**: Manages navigating story carousels, detecting next buttons, and extracting story metadata from the DOM.
- **`Instagram::Client::ApiAdapter`** (Existing): Manages HTTP JSON API calls when browser emulation is unnecessary.

### `InstagramProfileEvent`
Represents an immutable record of an event occurring on a profile (e.g., a story post). It includes the following extracted modules to separate concerns:
- **`InstagramProfileEvent::CommentGenerationCoordinator`**: Manages the state machine workflows for initiating, tracking, and completing LLM-generated comments.
- **`InstagramProfileEvent::Broadcastable`**: Encapsulates ActionCable WebSocket broadcasting logic for real-time UI updates (e.g., `broadcast_llm_comment_generation_queued`).
- **`InstagramProfileEvent::LocalStoryIntelligence`**: Parses local media files (images/videos) to extract ML-compatible analysis logic without ballooning the main model.

## Component Interaction

1. **Clients and Services**: The `Instagram::Client` includes its service modules using Ruby's `include` to provide a unified Public API. Callers (like background jobs) invoke `Instagram::Client.new`, which natively responds to `capture_home_feed_posts!`—delegated internally to the `FeedEngagementService`.
2. **Models and Concerns**: `InstagramProfileEvent` leverages `ActiveSupport::Concern`. When an event occurs, methods inside the `LocalStoryIntelligence` module parse the payload, and state transitions in `CommentGenerationCoordinator` trigger alerts through `Broadcastable`.

## Guidelines for Adding New Features

To prevent architectural drift and maintain a clean Dry/SOLID pattern:
1. **Never Add to God Objects**: If implementing a new Instagram feature (e.g., Reels engagement), **do not** add methods directly to `Instagram::Client`. Create a new module (e.g., `Instagram::Client::ReelsEngagementService`) and include it.
2. **Limit ActiveRecord Scope**: Models like `InstagramProfileEvent` should primarily handle associations, validations, and lifecycle callbacks. If logic relates to an external API (like ActionCable or OpenAI), extract it into a dedicated `Concern` or a Service Object.
3. **Keep Methods Small**: If an extracted module begins exceeding 400 lines, evaluate if it has violated the Single Responsibility Principle and split it further.
4. **Prefer Composition Over Inheritance**: Service classes in `app/services/` should generally be instantiated and injected with context (`account: @account`) rather than inheriting from giant base classes.

## Best Practices
- **Testing**: Whenever extracting a module from a God object, rely on existing integration/unit specs (like `spec/services/instagram`) to verify that the extraction behaves identically before committing.
- **Isolation**: Use `private` heavily within included modules to minimize the public footprint of the Facade objects.
