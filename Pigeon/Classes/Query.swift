//
//  Query.swift
//  Pigeon
//
//  Created by Fernando Martín Ortiz on 23/08/2020.
//  Copyright © 2020 Fernando Martín Ortiz. All rights reserved.
//

import Combine
import Foundation

public final class Query<Request, Response: Codable>: ObservableObject, QueryType, QueryInvalidationListener {
    public enum FetchingBehavior {
        case startWhenRequested
        case startImmediately(Request)
    }
    
    public enum PollingBehavior {
        case noPolling
        case pollEvery(TimeInterval)
    }

    var id: Int?
    public typealias State = QueryState<Response>
    public typealias QueryFetcher = (Request) async throws -> Response
    
    @Published public private(set) var state = State.idle
    
    public var statePublisher: AnyPublisher<QueryState<Response>, Never> {
        return $state.eraseToAnyPublisher()
    }

    public var valuePublisher: AnyPublisher<Response, Never> {
        $state
            .map { $0.value }
            .filter { $0 != nil }
            .map { $0! }
            .eraseToAnyPublisher()
    }

    private let key: QueryKey
    private let keyAdapter: (QueryKey, Request) -> QueryKey
    private let pollingBehavior: PollingBehavior
    private let cache: QueryCacheType
    private let cacheConfig: QueryCacheConfig
    private let fetcher: QueryFetcher
    private var lastRequest: Request?
    private var cancellables = Set<AnyCancellable>()
    private var timerCancellables = Set<AnyCancellable>()
    
    public init(
        key: QueryKey,
        keyAdapter: @escaping (QueryKey, Request) -> QueryKey = { key, _ in key },
        behavior: FetchingBehavior = .startWhenRequested,
        pollingBehavior: PollingBehavior = .noPolling,
        cache: QueryCacheType = QueryCache.global,
        cacheConfig: QueryCacheConfig = .global,
        fetcher: @escaping QueryFetcher
    ) {
        self.key = key
        self.keyAdapter = keyAdapter
        self.pollingBehavior = pollingBehavior
        self.cache = cache
        self.cacheConfig = cacheConfig
        self.fetcher = fetcher
        
        start(for: behavior)
        
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
    
    deinit {
        QueryRegistry.shared.unregister(for: key)
    }
    
    @MainActor
    public func refetch(request: Request) async {
        lastRequest = request
        timerCancellables.forEach { $0.cancel() }
        
        if cacheConfig.usagePolicy == .useIfFetchFails {
            state = .loading
        }

        await performFetch(for: request)
        startPollingIfNeeded(for: request)
    }
    
    private func start(for behavior: FetchingBehavior) {
        switch behavior {
        case .startWhenRequested:
            if cacheConfig.usagePolicy == .useInsteadOfFetching
                || cacheConfig.usagePolicy == .useAndThenFetch
            {
                if let cachedResponse: Response = getCacheValueIfPossible(for: key) {
                    state = .succeed(cachedResponse)
                }
            }
        case let .startImmediately(request):
            Task {
                await refetch(request: request)
            }
        }
    }
    
    private func startPollingIfNeeded(for request: Request) {
        switch pollingBehavior {
        case .noPolling:
            break
        case let .pollEvery(interval):
            Timer
                .publish(every: interval, on: .main, in: RunLoop.Mode.default)
                .autoconnect()
                .sink { _ in
                    Task {
                        await self.performFetch(for: request)
                    }
                }
                .store(in: &timerCancellables)
        }
    }
    
    private func isCacheValid(for key: QueryKey) -> Bool {
        return cache.isValueValid(
            forKey: key,
            timestamp: Date(),
            andInvalidationPolicy: cacheConfig.invalidationPolicy
        )
    }
    
    private func getCacheValueIfPossible(for key: QueryKey) -> Response? {
        if isCacheValid(for: key) {
            return cache.get(for: key)
        } else {
            return nil
        }
    }
    
    @MainActor
    private func performFetch(for request: Request) async {
        let key = keyAdapter(self.key, request)
        
        if cacheConfig.usagePolicy == .useInsteadOfFetching, isCacheValid(for: key) {
            if let value: Response = cache.get(for: key) {
                state = .succeed(value)
            }
            return
        }
        
        if cacheConfig.usagePolicy == .useAndThenFetch {
            if let value = getCacheValueIfPossible(for: key) {
                state = .succeed(value)
            }
        }
        
        do {
            let response = try await fetcher(request)
            state = .succeed(response)
            cache.save(
                response,
                for: key,
                andTimestamp: Date()
            )
        } catch {
            timerCancellables.forEach { $0.cancel() }
            if cacheConfig.usagePolicy == .useIfFetchFails {
                if let value = getCacheValueIfPossible(for: key) {
                    state = .succeed(value)
                } else {
                    state = .failed(error)
                }
            } else {
                state = .failed(error)
            }
        }
    }
}
