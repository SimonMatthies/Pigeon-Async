//
//  LazyQuery.swift
//  Pigeon
//
//  Created by Simon Matthies on 31.05.23.
//

import Combine
import Foundation

public final class LazyQuery<Request, PageIdentifier: PaginatedQueryKey, Response: Codable & Sequence>: ObservableObject, QueryType, QueryInvalidationListener {
    public enum FetchingBehavior {
        case startWhenRequested
        case startImmediately(Request)
    }

    public typealias State = QueryState<Response>
    public typealias QueryFetcher = (Request, PageIdentifier) async throws -> Response
    
    @Published public private(set) var items: [Response.Element] = []
    @Published private var internalState = State.idle
    @Published public private(set) var currentPage: PageIdentifier
    private var internalValuePublisher: AnyPublisher<Response, Never> {
        $internalState
            .map { $0.value }
            .filter { $0 != nil }
            .map { $0! }
            .eraseToAnyPublisher()
    }

    public var valuePublisher: AnyPublisher<Response, Never> {
        statePublisher
            .map { $0.value }
            .filter { $0 != nil }
            .map { $0! }
            .eraseToAnyPublisher()
    }

    public var state: QueryState<Response> {
        switch internalState {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case let .failed(error):
            return .failed(error)
        case .succeed:
            return .succeed(items as! Response)
        }
    }

    public var statePublisher: AnyPublisher<QueryState<Response>, Never> {
        $internalState
            .map { _ -> QueryState<Response> in
                self.state
            }
            .eraseToAnyPublisher()
    }

    private let key: QueryKey
    private let keyAdapter: (QueryKey, Request) -> QueryKey
    private let cache: QueryCacheType
    private let cacheConfig: QueryCacheConfig
    private let fetcher: QueryFetcher
    private var lastRequest: Request?
    private var cancellables = Set<AnyCancellable>()
    private var timerCancellables = Set<AnyCancellable>()
    
    public init(
        key: QueryKey,
        firstPage: PageIdentifier,
        keyAdapter: @escaping (QueryKey, Request) -> QueryKey = { key, _ in key },
        behavior: FetchingBehavior = .startWhenRequested,
        cache: QueryCacheType = QueryCache.global,
        cacheConfig: QueryCacheConfig = .global,
        fetcher: @escaping QueryFetcher
    ) {
        self.key = key
        self.currentPage = firstPage
        self.keyAdapter = keyAdapter
        self.cache = cache
        self.cacheConfig = cacheConfig
        self.fetcher = fetcher
        
        start(for: behavior)
        
        internalValuePublisher
            .sink { items in
                self.items.append(contentsOf: items)
            }
            .store(in: &cancellables)
        
        listenQueryInvalidation(for: key)
            .sink { (parameters: QueryInvalidator.TypedParameters<Request>) in
                switch parameters {
                case .lastData:
                    if let lastRequest = self.lastRequest {
                        Task {
                            await self.refetch(request: lastRequest)
                        }
                    }
                case let .newData(newRequest):
                    Task {
                        await self.refetch(request: newRequest)
                    }
                }
            }
            .store(in: &cancellables)
        
        QueryRegistry.shared.register(eraseToAnyQuery(), for: key)
    }
    
    private func start(for behavior: FetchingBehavior) {
        switch behavior {
        case .startWhenRequested:
            if cacheConfig.usagePolicy == .useInsteadOfFetching
                || cacheConfig.usagePolicy == .useAndThenFetch
            {
                if let cachedResponse: Response = getCacheValueIfPossible(for: key) {
                    internalState = .succeed(cachedResponse)
                }
            }
        case let .startImmediately(request):
            Task {
                await refetchPage(request: request, page: currentPage)
            }
        }
    }
    
    private func isCacheValid(for key: QueryKey) -> Bool {
        return cache.isValueValid(
            forKey: key.appending(currentPage),
            timestamp: Date(),
            andInvalidationPolicy: cacheConfig.invalidationPolicy
        )
    }
    
    private func getCacheValueIfPossible(for key: QueryKey) -> Response? {
        if isCacheValid(for: key) {
            return cache.get(for: key.appending(currentPage))
        } else {
            return nil
        }
    }
    
    @MainActor
    public func fetchNextPage() async {
        guard let lastRequest = lastRequest else {
            return
        }
        
        currentPage = currentPage.next
        await refetchPage(request: lastRequest, page: currentPage)
    }
    
    @MainActor
    public func refetch(request: Request) async {
        items = []
        currentPage = currentPage.first
        await refetchCurrent(request: request)
    }
    
    @MainActor
    private func refetchCurrent(request: Request) async {
        await refetchPage(request: request, page: currentPage)
    }
    
    @MainActor
    private func refetchPage(request: Request, page: PageIdentifier) async {
        let key = keyAdapter(self.key, request)
        
        lastRequest = request
        currentPage = page
        
        if cacheConfig.usagePolicy == .useInsteadOfFetching, isCacheValid(for: key) {
            if let value: Response = cache.get(for: key) {
                internalState = .succeed(value)
            }
            return
        }
        
        if cacheConfig.usagePolicy == .useAndThenFetch {
            if let value = getCacheValueIfPossible(for: key) {
                internalState = .succeed(value)
            }
        }
        
        if cacheConfig.usagePolicy == .useIfFetchFails {
            internalState = .loading
        }
        
        do {
            let response = try await fetcher(request, page)
            items.append(contentsOf: response)
            internalState = .succeed(items as! Response)
            cache.save(response, for: key.appending(currentPage), andTimestamp: Date())
        } catch {
            timerCancellables.forEach { $0.cancel() }
            if cacheConfig.usagePolicy == .useIfFetchFails {
                if let value = getCacheValueIfPossible(for: key) {
                    internalState = .succeed(value)
                } else {
                    internalState = .failed(error)
                }
            } else {
                internalState = .failed(error)
            }
        }
    }
}
