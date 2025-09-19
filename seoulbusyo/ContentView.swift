//
//  Busyo_SingleFile.swift
//  CITY_CODE=25 / 제스처 종료 후 1회 호출 / Arrivals→BusLoc / 클러스터링
//  + 버스=파랑, 정류장=빨강 / API 카운터 / 내 위치 버튼
//  + [FIX] 선택해도 다른 버스 안 사라짐(가시성 제거 → 데이터 기준 제거)
//  + [FIX] 선택 상태에서도 좌표 갱신/애니메이션 반영(KVO)
//  + [ADD] 말풍선·마커 subtitle에 “다음 정류장 · ETA분” (KVO)
//  + [ADD] Dead-reckoning, EMA 스무딩, 스냅, 점프 제거
//  + [FIX] 팔로우 해제 후 재추적 가능 / 겹치면 버스 우선 / 팔로우 이동 시 정류장 자동 로드
//

import SwiftUI
import MapKit
import CoreLocation
import Foundation
import simd


// MARK: - App
@main
struct BusyoApp: App {
//    init() {
//        GADMobileAds.sharedInstance().start(completionHandler: nil)
//        }
    var body: some Scene { WindowGroup { BusMapScreen() } }
}
struct UpcomingStopETA: Identifiable {
    let id: String
    let name: String
    let etaMin: Int
}
import os

enum DBG {
    static let api  = Logger(subsystem: "app.bus", category: "API")
    static let vm   = Logger(subsystem: "app.bus", category: "VM")
    static let map  = Logger(subsystem: "app.bus", category: "MAP")
    static let view = Logger(subsystem: "app.bus", category: "VIEW")
}
extension Double {
    func fixed(_ n: Int) -> String {
        String(format: "%.\(n)f", self)
    }
}

// 문자열을 안전하게 로그로 보내는 헬퍼

struct StationResponse: Decodable {
    let msgBody: StationMsgBody
}

struct StationMsgBody: Decodable {
    let itemList: [StationItem]?
}

struct StationItem: Decodable {
    let stationId: String
    let stationNm: String
    let gpsX: Double
    let gpsY: Double
}


@inline(__always)
func tick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@inline(__always)
func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0 }

private let SEOUL_CITY_HALL = CLLocationCoordinate2D(latitude: 37.5662952, longitude: 126.9779451)

// MARK: - Geo util
fileprivate struct GeoUtil {
    static func metersPerDegLat(at lat: Double) -> Double { 111_320 }
    static func metersPerDegLon(at lat: Double) -> Double { 111_320 * cos(lat * .pi/180) }
    static func deltaMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (dx: Double, dy: Double, dist: Double) {
        let mLat = metersPerDegLat(at: (a.latitude + b.latitude)/2)
        let mLon = metersPerDegLon(at: (a.latitude + b.latitude)/2)
        let dy = (b.latitude  - a.latitude ) * mLat
        let dx = (b.longitude - a.longitude) * mLon
        return (dx, dy, hypot(dx, dy))
    }
}

// MARK: - Const & Utils
private let CITY_CODE = 25
private let MIN_RELOAD_DIST: CLLocationDistance = 250
private let MIN_ZOOM_RATIO: CGFloat = 0.10
private let REGION_COOLDOWN_SEC: Double = 6.0
private let BUS_REFRESH_SEC: UInt64 = 5
private let SHOW_DEBUG = false

fileprivate extension String {
    var encodedForServiceKey: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
fileprivate func maskKey(_ k: String) -> String { k.count > 12 ? "\(k.prefix(6))...\(k.suffix(6))" : "****" }

// MARK: - Models
struct BusStop: Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
}
struct BusLive: Identifiable, Hashable {
    let id: String
    let routeNo: String
    var lat: Double
    var lon: Double
    var etaMinutes: Int?
    var nextStopName: String?
}
struct ArrivalInfo: Identifiable, Hashable { let id = UUID(); let routeId: String; let routeNo: String; let etaMinutes: Int }
enum APIError: Error { case invalidURL, http(Int), decode(Error) }

// MARK: - Flex decoders
// 유틸: 문자열/숫자 어떤 타입이 와도 흡수
// 유연 파서 도우미
struct FlexString: Decodable {
    let value: String
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = "" }
    }
}
struct OneOrMany<T: Decodable>: Decodable {
    let array: [T]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(T.self) { array = [one] }
        else { array = (try? c.decode([T].self)) ?? []
        }
    }
}
struct ItemsFlex<T: Decodable>: Decodable {
    let values: [T]
    private struct Box<U: Decodable>: Decodable { let item: OneOrMany<U>? }
    init(from decoder: Decoder) throws {
        if let sv = try? decoder.singleValueContainer() {
            if sv.decodeNil() || (try? sv.decode(String.self)) != nil { values = []; return }
        }
        if let box = try? Box<T>(from: decoder) { values = box.item?.array ?? []; return }
        if let arr = try? [T](from: decoder) { values = arr; return }
        values = []
    }
}
struct FlexInt: Decodable {
    let value: Int?
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else { value = nil }
    }
}
struct FlexDouble: Decodable {
    let value: Double
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let v = try? c.decode(Double.self) { value = v }
        else if let s = try? c.decode(String.self), let v = Double(s.replacingOccurrences(of: ",", with: "")) { value = v }
        else { throw DecodingError.typeMismatch(Double.self, .init(codingPath: d.codingPath, debugDescription: "not double/string")) }
    }
}

// MARK: - API Counter (thread-safe)
actor APICounter {
    static let shared = APICounter()
    private var total: Int = 0
    private var per: [String: Int] = [:]
    func bump(_ tag: String) {
        total += 1; per[tag, default: 0] += 1
        let parts = per.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  ")
        print("🧮🟨 [API COUNT] total=\(total)  \(parts)")
    }
}

// MARK: - API
final class BusAPI: NSObject, URLSessionDelegate {
    private let serviceKeyRaw = "FVUZJTrP1WLAsFAKcXy8lh2Qy1DWNw5Ul2+vSY01E3cUJlO/9P+CodODXPIyzppQCPswXvc1WeblEAh6X41ClA=="
    // BusAPI 내 (저장돼 있는) 평문 키
    // BusAPI.swift
    private let seoulServiceKeyDecoding = "FVUZJTrP1WLAsFAKcXy8lh2Qy1DWNw5Ul2+vSY01E3cUJlO/9P+CodODXPIyzppQCPswXvc1WeblEAh6X41ClA=="
    
    private let seoulServiceKeyEncoding = "FVUZJTrP1WLAsFAKcXy8lh2Qy1DWNw5Ul2%2BvSY01E3cUJlO%2F9P%2BCodODXPIyzppQCPswXvc1WeblEAh6X41ClA%3D%3D"
    
    // BusAPI 안
    func makeSeoulURL(path: String, params: [URLQueryItem]) -> URL {
        var comp = URLComponents()
        comp.scheme = "http"               // 중요: http
        comp.host   = "ws.bus.go.kr"
        comp.path   = "/api/rest" + path   // 예: "/stationinfo/getStationByPos"

        // 서비스키는 '원본' 그대로 넣고, 나머지만 쿼리아이템으로
        var items: [URLQueryItem] = []
        var serviceKeyRaw: String? = nil
        for p in params {
            if p.name == "serviceKey" { serviceKeyRaw = p.value }
            else { items.append(p) }
        }
        comp.queryItems = items

        var url = comp.url!
        if let key = serviceKeyRaw {    // serviceKey는 수동으로 이어붙이기(이중 인코딩 방지)
            let sep = (comp.queryItems?.isEmpty ?? true) ? "?" : "&"
            url = URL(string: url.absoluteString + "\(sep)serviceKey=\(key)")!
        }

        print("👉 Seoul URL = \(url)")
        return url
    }

//    private func makeSeoulURL(base: String, params: [URLQueryItem]) -> URL {
//        // 1) 나머지 파라미터를 URLComponents로 일반 인코딩
//        var comps = URLComponents(string: base)!
//        comps.queryItems = params
//        let rest = comps.percentEncodedQuery.map { "&" + $0 } ?? ""
//        
//        // 2) serviceKey는 **이미 인코딩된 값**을 그대로 붙이기 (재인코딩 금지)
//        var finalComps = URLComponents(string: base)!
//        finalComps.percentEncodedQuery = "serviceKey=\(seoulServiceKeyEncoding)\(rest)"
//        
//        return finalComps.url!
//    }
    // BusAPI 안 공통 통신 함수 대체
    private let URL_TIMEOUT_REQ: TimeInterval = 20     // 요청 타임아웃
    private let URL_TIMEOUT_RES: TimeInterval = 30
    // 쿼리값에 쓸 때 정확히 한 번만 인코딩
    private var serviceKeyEncoded: String {
        serviceKeyRaw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? serviceKeyRaw
    }
    
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = true
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
    /// 서울시: 노선 경로 점열
    // BusAPI 내부 전체 교체 (서울시: 노선 경로)
    //    func fetchRoutePath(cityCode: Int, routeId: String) async throws -> [CLLocationCoordinate2D] {
    //        guard var comps = URLComponents(string: "http:://ws.bus.go.kr/api/rest/busRouteInfo/getRoutePath") else {
    //            throw APIError.invalidURL
    //        }
    //        comps.queryItems = [
    //            .init(name: "serviceKey", value: serviceKeyRaw),   // ← raw!
    //            .init(name: "busRouteId", value: routeId)
    //        ]
    //        guard let url = comps.url else { throw APIError.invalidURL }
    //
    //        let (data, _) = try await send("RoutePath(Seoul)", url: url)
    //        let arr = try parseXMLItems(data)
    //
    //        func dd(_ d: [String:String], _ keys: [String]) -> Double? {
    //            for k in keys { if let v = d[k] ?? d[k.lowercased()], let x = Double(v) { return x } }
    //            return nil
    //        }
    //        return arr.compactMap { d in
    //            guard let la = dd(d, ["gpsY","y"]), let lo = dd(d, ["gpsX","x"]) else { return nil }
    //            return .init(latitude: la, longitude: lo)
    //        }
    //    }
    // BusAPI
    func fetchRoutePath(cityCode: Int, routeId: String) async throws -> [CLLocationCoordinate2D] {
        // 서울시는 폴리라인 API가 사실상 없어, MapVM의 폴백(정류장 연결)로 처리.
        // 여기서는 빈 배열을 돌려 폴백을 트리거한다.
        return []
    }
    
    
    
    func fetchBusLocationsDaejeon(routeId: String) async throws -> [BusLive] {
        guard var comps = URLComponents(string: "http://openapittraffic.daejeon.go.kr/api/rest/busposinfo/getBusPosByRtid") else {
            throw APIError.invalidURL
        }
        comps.queryItems = [
            .init(name: "serviceKey", value: serviceKeyEncoded), // ← encoded 속성 사용
            .init(name: "busRouteId", value: routeId)
        ]
        guard let url = comps.url else { throw APIError.invalidURL }

        let (data, _) = try await send("BusLoc(DJ)", url: url)
        let arr = try parseXMLItems(data)

        func dbl(_ d:[String:String], _ ks:[String]) -> Double? {
            for k in ks { if let v = d[k] ?? d[k.lowercased()], let x = Double(v) { return x } }
            return nil
        }
        func str(_ d:[String:String], _ ks:[String]) -> String? {
            for k in ks { if let v = d[k] ?? d[k.lowercased()], !v.isEmpty { return v } }
            return nil
        }

        return arr.compactMap { d in
            let veh = str(d, ["vehicleno","carNo","carno"]) ?? ""
            let rno = str(d, ["routeno","routenm","routeNo","routeNm"]) ?? "?"
            let lat = dbl(d, ["gpsLati","gpsY","wgs84Lat","lat"])
            let lon = dbl(d, ["gpsLong","gpsX","wgs84Lon","lon"])
            guard !veh.isEmpty, let la = lat, let lo = lon else { return nil }
            let nextNm = str(d, ["nodeNm","nodenm","nextStop","stationNm"])
            return BusLive(id: veh, routeNo: rno, lat: la, lon: lo, etaMinutes: nil, nextStopName: nextNm)
        }
    }

    func fetchStopsByRouteDaejeon(routeId: String) async throws -> [BusStop] {
        guard var comps = URLComponents(string: "http://openapittraffic.daejeon.go.kr/api/rest/busRouteInfo/getStaionByRtid") else {
            throw APIError.invalidURL
        }
        comps.queryItems = [
            .init(name: "serviceKey", value: serviceKeyEncoded), // ← encoded
            .init(name: "busRouteId", value: routeId)
        ]
        guard let url = comps.url else { throw APIError.invalidURL }

        let (data, _) = try await send("RouteStops(DJ)", url: url)
        let arr = try parseXMLItems(data)

        func str(_ d:[String:String], _ ks:[String]) -> String? {
            for k in ks { if let v = d[k] ?? d[k.lowercased()], !v.isEmpty { return v } }
            return nil
        }
        func dbl(_ d:[String:String], _ ks:[String]) -> Double? { str(d, ks).flatMap(Double.init) }

        return arr.compactMap { d in
            guard
                let id   = str(d, ["nodeid","stationId","stopId"]),
                let name = str(d, ["nodenm","stationNm","stopNm"]),
                let lat  = dbl(d, ["gpsY","wgs84Lat","gpsLati","lat"]),
                let lon  = dbl(d, ["gpsX","wgs84Lon","gpsLong","lon"])
            else { return nil }
            return BusStop(id: id, name: name, lat: lat, lon: lon)
        }
    }

    
    // BusAPI 내부 전체 교체 (서울시: 노선 정류장)
    // BusAPI
    func fetchStopsByRoute(cityCode: Int, routeId: String) async throws -> [BusStop] {
        // 서울시: /busRouteInfo/getStaionByRoute
        let url = makeSeoulURL(
            path: "/busRouteInfo/getStaionByRoute",
            params: [
                .init(name: "serviceKey", value: serviceKeyEncoded), // ← raw 그대로
                .init(name: "busRouteId", value: routeId),
                .init(name: "resultType", value: "json")
            ])

        struct Root: Decodable {
            struct ServiceResult: Decodable {
                struct Body: Decodable { let itemList: OneOrMany<Item>? }
                let msgBody: Body?
            }
            struct Item: Decodable {
                let stId: String?
                let arsId: String?
                let stationNm: String?
                let gpsX: String?
                let gpsY: String?
            }
            let ServiceResult: ServiceResult?
        }

        let (data, http) = try await send("RouteStops(Seoul)", url: url)
        if let s = String(data: data, encoding: .utf8) {
            print("🔎 RouteStops raw(\(http.statusCode)): \(s.prefix(240))")
        }

        let r = try JSONDecoder().decode(Root.self, from: data)
        let items = r.ServiceResult?.msgBody?.itemList?.array ?? []

        func toDouble(_ s: String?) -> Double? { s.flatMap(Double.init) }

        return items.compactMap { it in
            guard let lat = toDouble(it.gpsY), let lon = toDouble(it.gpsX) else { return nil }
            let id   = it.stId ?? it.arsId ?? UUID().uuidString
            let name = it.stationNm ?? (it.arsId.map { "정류장 \($0)" } ?? "정류장")
            return BusStop(id: id, name: name, lat: lat, lon: lon)
        }
    }


    
    private func urlWithEncodedKey(base: String, items: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw APIError.invalidURL }
        comps.queryItems = items
        let tail = comps.percentEncodedQuery ?? ""
        comps.percentEncodedQuery = "serviceKey=\(serviceKeyEncoded)" + (tail.isEmpty ? "" : "&\(tail)")
        guard let url = comps.url else { throw APIError.invalidURL }
        return url
    }

    
    // BusAPI 내부: 아래 메서드로 교체
    // BusAPI 내부 교체(선택)
    @discardableResult
    func send(_ tag: String, url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: URL_TIMEOUT_REQ)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = URL_TIMEOUT_REQ
        cfg.timeoutIntervalForResource = URL_TIMEOUT_RES
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true

        let session = URLSession(configuration: cfg)
        let t0 = Date()

        DBG.api.log("➡️ [REQ \(tag)] \(url.absoluteString)")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                DBG.api.error("❌ [\(tag)] non-HTTP response")
                throw URLError(.badServerResponse)
            }

            // 앞 600자 스니펫 로깅(성공/오류 공통)
            let snippet = (String(data: data, encoding: .utf8) ?? "—")
                .replacingOccurrences(of: "\n", with: " ")
            DBG.api.log("⬅️ [RES \(tag)] status=\(http.statusCode) ms=\(Int(Date().timeIntervalSince(t0)*1000)) body=\(snippet.prefix(600))")

            if (200..<300).contains(http.statusCode) == false { throw URLError(.badServerResponse) }
            return (data, http)
        } catch {
            let ms = Int(Date().timeIntervalSince(t0)*1000)
            DBG.api.error("❌ [\(tag)] error=\(error) ms=\(ms)")
            throw error
        }
    }

    
    private func isLikelyXML(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        for ch in s { if ch == "<" { return true }; if ch.isWhitespace { continue }; break }
        return false
    }
    
    private final class XMLItemsParser: NSObject, XMLParserDelegate {
        var items: [[String:String]] = []; private var cur: [String:String]?; private var key: String?; private var buf = ""
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
            let k = name.lowercased(); if k == "item" { cur = [:] } else if cur != nil { key = k; buf = "" }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { buf += s }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            let k = name.lowercased()
            if k == "item" { if let c = cur { items.append(c) }; cur = nil }
            else if let kk = key, cur != nil {
                let v = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { cur?[kk] = v }
                key = nil; buf = ""
            }
        }
    }
    private func parseXMLItems(_ data: Data) throws -> [[String:String]] {
        let p = XMLItemsParser()
        let xp = XMLParser(data: data); xp.delegate = p
        guard xp.parse() else { throw APIError.decode(xp.parserError ?? NSError(domain: "XML", code: -1)) }
        return p.items
    }
    
    private func toDouble(_ s: String?) -> Double? { s.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) } }
    private func toInt(_ s: String?) -> Int? { s.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } }
    
    /// 서울시: 좌표 주변 정류장 (tmX/tmY ← WGS84 lon/lat 그대로 넣으면 동작)
    // BusAPI 내부: 메서드 전체 교체 (서울시: 주변 정류장)
    /// 서울시: 좌표 주변 정류소 조회 (JSON)
    func fetchStops(lat: Double, lon: Double) async throws -> [BusStop] {
        let url = makeSeoulURL(
            path: "/stationinfo/getStationByPos",
            params: [
                .init(name: "serviceKey", value: serviceKeyEncoded), // ← 인코딩된 키
                .init(name: "tmX", value: String(lon)),
                .init(name: "tmY", value: String(lat)),
                .init(name: "radius", value: "800"),
                .init(name: "resultType", value: "json")
            ]
        )

        let (data, http) = try await URLSession.shared.data(from: url)
        print("📡 fetchStops HTTP status:", (http as? HTTPURLResponse)?.statusCode ?? -1)
        if let s = String(data: data, encoding: .utf8) {
            print("📄 fetchStops raw JSON:", s.prefix(300))
        }

        // ✅ 응답 모델: 좌표는 문자열로 받기
        struct StationResponse: Decodable {
            struct MsgBody: Decodable {
                let itemList: [Item]?
            }
            struct Item: Decodable {
                let stationId: String
                let stationNm: String
                let gpsX: String   // ← String
                let gpsY: String   // ← String
            }
            let msgBody: MsgBody
        }

        let decoded = try JSONDecoder().decode(StationResponse.self, from: data)
        let items = decoded.msgBody.itemList ?? []

        func toDouble(_ s: String) -> Double? {
            // 혹시 콤마가 끼어오는 경우 대비
            Double(s.replacingOccurrences(of: ",", with: ""))
        }

        let stops: [BusStop] = items.compactMap { it in
            guard let lon = toDouble(it.gpsX),
                  let lat = toDouble(it.gpsY) else { return nil }
            return BusStop(id: it.stationId, name: it.stationNm, lat: lat, lon: lon)
        }

        print("✅ parsed stops:", stops.count)
        return stops
    }




//       func fetchStops(lat: Double, lon: Double) async throws -> [BusStop] {
//           // 서울시 API는 tmX=경도, tmY=위도(도 단위)로 넣어도 동작합니다.
//           let base = "http:://ws.bus.go.kr/api/rest/stationinfo/getStationByPos"
//
//           // resultType=json 필수, serviceKey는 makeSeoulURL에서 percentEncodedQuery로 붙임
//           let url = makeSeoulURL(
//               base: base,
//               params: [
//                   .init(name: "tmX", value: String(lon)),
//                   .init(name: "tmY", value: String(lat)),
//                   .init(name: "radius", value: "800"),
//                   .init(name: "resultType", value: "json")
//               ]
//           )
//
//           // 요청
//           let (data, http) = try await send("Stops(Seoul)", url: url)
//
//           // 미리보기 로그
//           if let s = String(data: data, encoding: .utf8) {
//               let p = s.prefix(240)
//               print("⬅️ [RES Stops(Seoul)] \(http.statusCode)  \(data.count)b  preview=\(p)")
//           }
//
//           // 디코딩 구조체
//           struct Root: Decodable {
//               let ServiceResult: ServiceResult?
//           }
//           struct ServiceResult: Decodable {
//               let msgHeader: MsgHeader?
//               let msgBody: MsgBody?
//           }
//           struct MsgHeader: Decodable {
//               let headerCd: Int?
//               let headerMsg: String?
//               let itemCount: Int?
//           }
//           struct MsgBody: Decodable {
//               let itemList: [Item]?
//           }
//           struct Item: Decodable {
//               let stId: String?       // 내부 정류소 ID
//               let arsId: String?      // 도로변 고유번호(표지판 번호)
//               let stationNm: String?  // 정류소명
//               let tmX: String?        // 경도(문자열일 수 있음)
//               let tmY: String?        // 위도
//               let gpsX: String?       // 경도(일부 응답에 존재)
//               let gpsY: String?       // 위도
//           }
//
//           // JSON 파싱
//           let root = try JSONDecoder().decode(Root.self, from: data)
//
//           // 에러 헤더 처리(있으면 로그만)
//           if let cd = root.ServiceResult?.msgHeader?.headerCd,
//              cd != 0 {
//               let msg = root.ServiceResult?.msgHeader?.headerMsg ?? ""
//               print("⚠️ Stops(Seoul) headerCd=\(cd) msg=\(msg)")
//           }
//
//           let items = root.ServiceResult?.msgBody?.itemList ?? []
//
//           // 좌표 선택: gpsX/gpsY 우선, 없으면 tmX/tmY 사용
//           func toDouble(_ s: String?) -> Double? {
//               guard let s, !s.isEmpty else { return nil }
//               return Double(s)
//           }
//
//           let stops: [BusStop] = items.compactMap { it in
//               let lon = toDouble(it.gpsX) ?? toDouble(it.tmX)
//               let lat = toDouble(it.gpsY) ?? toDouble(it.tmY)
//               if let lat, let lon {
//                   let id = it.stId ?? it.arsId ?? UUID().uuidString
//                   let name = it.stationNm ?? (it.arsId.map { "정류장 \($0)" } ?? "정류장")
//                   return BusStop(id: id, name: name, lat: lat, lon: lon, cityCode: 1000)
//               } else {
//                   return nil
//               }
//           }
//
//
//           return stops
//       }


    
    
    /// 내부: 정류장(arsId) → 경유 노선(버스RouteId/rtNm/stId/staOrd) 목록
    private func fetchRoutesAtStation(arsId: String) async throws
    -> [(busRouteId: String, rtNm: String, stId: String, ord: String)] {
        guard var comps = URLComponents(string: "http://ws.bus.go.kr/api/rest/stationinfo/getRouteByStation") else {
            throw APIError.invalidURL
        }
        comps.queryItems = [
            .init(name: "serviceKey", value: serviceKeyEncoded), // ← encoded
            .init(name: "arsId", value: arsId)
        ]
        guard let url = comps.url else { throw APIError.invalidURL }

        let (data, _) = try await send("RoutesAtStation(Seoul)", url: url)
        let arr = try parseXMLItems(data)

        func ss(_ d:[String:String], _ ks:[String]) -> String? {
            for k in ks { if let v = d[k] ?? d[k.lowercased()], !v.isEmpty { return v } }
            return nil
        }

        return arr.compactMap { it in
            guard
                let rid = ss(it, ["busRouteId","busrouteid"]),
                let rnm = ss(it, ["rtNm","rtnm"]),
                let st  = ss(it, ["stId","station"]),
                let ord = ss(it, ["staOrd","ord"])
            else { return nil }
            return (rid, rnm, st, ord)
        }
    }

    // 2) 정류장 ETA
    // ✅ arsId(표지판 번호) 정상화: 앞자리 0 보존
    private func normalizeArsId(_ s: String) -> String {
        // 공공데이터 포털의 arsId는 문자열 취급이 정석. 혹시 Int로 들고왔다면 패딩.
        if s.allSatisfy(\.isNumber) && s.count < 5 {
            // 보편적으로 5자리(서울)라 5자리로 패딩. 지역별로 다르면 모델에서 그대로 문자열을 들고오도록 권장.
            return String(repeating: "0", count: 5 - s.count) + s
        }
        return s
    }

    // ✅ 도착정보: 404 대응, arsId 정상화, XML 폴백
    func fetchArrivalsDetailed(cityCode: Int, nodeId rawArsId: String) async throws -> [ArrivalInfo] {
        let arsId = normalizeArsId(rawArsId)

        // 1) JSON 시도 (일부 환경에선 잘 동작)
        var url = makeSeoulURL(
            path: "/arrive/getArrInfoByUid",
            params: [
                .init(name: "serviceKey", value: serviceKeyEncoded),
                .init(name: "arsId", value: arsId),
                .init(name: "resultType", value: "json")
            ]
        )
        DBG.api.log("➡️ [Arrivals URL(JSON)] \(url.absoluteString)")

        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let s = String(data: data, encoding: .utf8) {
                DBG.api.log("🔎 Arrivals raw(\(code)): \(s.prefix(400))")
            }
            if code == 404 {
                throw URLError(.badServerResponse) // 아래 XML 경로로 재시도
            }

            // JSON 파싱
            struct Root: Decodable {
                struct ServiceResult: Decodable {
                    struct Body: Decodable { let itemList: OneOrMany<Item>? }
                    let msgBody: Body?
                }
                struct Item: Decodable {
                    let busRouteId: String?
                    let rtNm: String?
                    let arrmsg1: String?
                    let arrmsg2: String?
                }
                let ServiceResult: ServiceResult?
            }

            if let r = try? JSONDecoder().decode(Root.self, from: data) {
                let items = r.ServiceResult?.msgBody?.itemList?.array ?? []
                return items.compactMap { it in
                    guard let rid = it.busRouteId, let rno = it.rtNm else { return nil }
                    let eta = parseETA(it.arrmsg1) ?? parseETA(it.arrmsg2) ?? 0
                    return ArrivalInfo(routeId: rid, routeNo: rno, etaMinutes: eta)
                }
            } else {
                // JSON 파싱 실패 → XML 폴백
                let arr = try parseXMLItems(data)
                return arr.compactMap { d in
                    let rid = d["busRouteId"] ?? d["busrouteid"]
                    let rno = d["rtNm"] ?? d["rtnm"]
                    let eta = parseETA(d["arrmsg1"]) ?? parseETA(d["arrmsg2"]) ?? 0
                    guard let rid, let rno else { return nil }
                    return ArrivalInfo(routeId: rid, routeNo: rno, etaMinutes: eta)
                }
            }
        } catch {
            // 2) 404/파싱 실패 시: resultType 제거(XML 전용 경로)로 재시도
            url = makeSeoulURL(
                path: "/arrive/getArrInfoByUid",
                params: [
                    .init(name: "serviceKey", value: serviceKeyEncoded),
                    .init(name: "arsId", value: arsId)
                ]
            )
            DBG.api.log("↩️ [Arrivals URL(XML retry)] \(url.absoluteString)")

            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let s = String(data: data, encoding: .utf8) {
                DBG.api.log("🔎 Arrivals(XML) raw(\(code)): \(s.prefix(400))")
            }
            guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }

            let arr = try parseXMLItems(data)
            return arr.compactMap { d in
                let rid = d["busRouteId"] ?? d["busrouteid"]
                let rno = d["rtNm"] ?? d["rtnm"]
                let eta = parseETA(d["arrmsg1"]) ?? parseETA(d["arrmsg2"]) ?? 0
                guard let rid, let rno else { return nil }
                return ArrivalInfo(routeId: rid, routeNo: rno, etaMinutes: eta)
            }
        }
    }

    // 공통 ETA 파서 (그대로 사용)
    private func parseETA(_ text: String?) -> Int? {
        guard let t = text else { return nil }
        if t.contains("곧 도착") || (t.contains("도착") && !t.contains("전")) { return 0 }
        let tokens = t.split(whereSeparator: { $0.isWhitespace })
        if let tok = tokens.first(where: { $0.contains("분") }) {
            if let v = Int(tok.replacingOccurrences(of: "분", with: "")) { return max(0, v) }
        }
        return 0
    }


    
    func fetchBusLocations(cityCode: Int, routeId: String) async throws -> [BusLive] {
        let url = makeSeoulURL(
            path: "/buspos/getBusPosByRtid",
            params: [
                .init(name: "serviceKey", value: serviceKeyEncoded), // raw
                .init(name: "busRouteId", value: routeId),
                .init(name: "resultType", value: "json")
            ])

        struct Root: Decodable {
            struct ServiceResult: Decodable {
                struct Body: Decodable { let itemList: OneOrMany<Item>? }
                let msgBody: Body?
            }
            struct Item: Decodable {
                let vehId: String?
                let plainNo: String?
                let gpsX: String?
                let gpsY: String?
                let rtNm: String?
            }
            let ServiceResult: ServiceResult?
        }

        let (data, http) = try await send("BusPos(Seoul)", url: url)
        if let s = String(data: data, encoding: .utf8) {
            print("🔎 BusPos raw(\(http.statusCode)): \(s.prefix(240))")
        }

        let r = try JSONDecoder().decode(Root.self, from: data)
        let items = r.ServiceResult?.msgBody?.itemList?.array ?? []

        func toDouble(_ s: String?) -> Double? { s.flatMap(Double.init) }

        return items.compactMap { it in
            let id = it.vehId ?? it.plainNo
            guard let id, let lon = toDouble(it.gpsX), let lat = toDouble(it.gpsY) else { return nil }
            let routeNo = it.rtNm ?? "?"
            return BusLive(id: id, routeNo: routeNo, lat: lat, lon: lon, etaMinutes: nil, nextStopName: nil)
        }
    }



}

// MARK: - Annotations
final class BusStopAnnotation: NSObject, MKAnnotation {
    let stop: BusStop
    @objc dynamic var coordinate: CLLocationCoordinate2D
    
    var title: String? { stop.name }
    init(_ s: BusStop) { self.stop = s; self.coordinate = .init(latitude: s.lat, longitude: s.lon) }
}

final class BusAnnotation: NSObject, MKAnnotation {
    let id: String
    let routeNo: String

    // 콜아웃/라벨 표시용 최신 값 (Obj-C KVO 불필요)
    private(set) var nextStopName: String?
    private(set) var etaMinutes: Int?

    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { routeNo }

    // KVO 가능한 subtitleStorage만 유지 (marker subtitle 갱신용)
    @objc dynamic private var subtitleStorage: String?
    var subtitle: String? { subtitleStorage }

    init(bus: BusLive) {
        id = bus.id
        routeNo = bus.routeNo
        coordinate = .init(latitude: bus.lat, longitude: bus.lon)
        nextStopName = bus.nextStopName
        etaMinutes   = bus.etaMinutes
        super.init()
        setSubtitle(Self.makeSubtitle(eta: bus.etaMinutes, next: bus.nextStopName))
    }

    private static func makeSubtitle(eta: Int?, next: String?) -> String? {
        switch (eta, next) {
        case let (.some(e), .some(n)): return "다음 \(n) · 약 \(e)분"
        case let (.none, .some(n)):    return "다음 \(n)"
        case let (.some(e), .none):    return "약 \(e)분"
        default:                       return nil
        }
    }

    // BusAnnotation.swift
    private func setSubtitle(_ s: String?) {
        // CRASH FIX: subtitle KVO를 다음 런루프로 미뤄서 MapKit 내부 열거와 충돌 방지
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.willChangeValue(forKey: "subtitle")
            self.subtitleStorage = s
            self.didChangeValue(forKey: "subtitle")
        }
    }


    func update(to b: BusLive) {
        // 값 갱신
        self.nextStopName = b.nextStopName
        self.etaMinutes   = b.etaMinutes
        // 마커 subtitle 즉시 반영
        setSubtitle(Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName))

        // 좌표 애니메이션
        let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        self.coordinate = newC
        CATransaction.commit()
    }
    
    // BusAnnotation.swift

    @MainActor func update(to b: BusLive, vm: MapVM) {
        self.nextStopName = b.nextStopName
        self.etaMinutes   = b.etaMinutes
        setSubtitle(Self.makeSubtitle(eta: b.etaMinutes, next: b.nextStopName))

        let newC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        self.coordinate = newC
        CATransaction.commit()

        // ✅ VM에 다음 정류장 업데이트
        vm.updateHighlightStop(for: b)
    }

}

// 기존 BusMarkerView 전체 교체
final class BusMarkerView: MKMarkerAnnotationView {
    private let bubble = UIView()
    private let bubbleLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        titleVisibility = .hidden
        subtitleVisibility = .hidden
        canShowCallout = false

        glyphImage = UIImage(systemName: "bus.fill")
        glyphTintColor = .white
        centerOffset = CGPoint(x: 0, y: -10)
        collisionMode = .circle
        displayPriority = .required
        layer.zPosition = 10
        clipsToBounds = false

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        bubble.layer.cornerRadius = 6
        bubble.layer.masksToBounds = true

        bubbleLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleLabel.font = .systemFont(ofSize: 11)
        bubbleLabel.textColor = .label
        bubbleLabel.numberOfLines = 1
        bubbleLabel.adjustsFontSizeToFitWidth = true
        bubbleLabel.minimumScaleFactor = 0.7
        bubbleLabel.lineBreakMode = .byTruncatingTail

        addSubview(bubble)
        bubble.addSubview(bubbleLabel)

        NSLayoutConstraint.activate([
            bubble.centerXAnchor.constraint(equalTo: centerXAnchor),
            bubble.bottomAnchor.constraint(equalTo: topAnchor, constant: -2),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            bubbleLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            bubbleLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            bubbleLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 4),
            bubbleLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureTint(isFollowed: Bool) {
        markerTintColor = isFollowed ? .systemGreen : .systemBlue
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let b = annotation as? BusAnnotation { glyphText = b.routeNo }
        updateAlwaysOnBubble()
    }

    func updateAlwaysOnBubble() {
        guard let a = annotation as? BusAnnotation else { return }
        let text: String? = {
            if let next = a.nextStopName, let eta = a.etaMinutes {
                return "다음 \(next) · \(eta)분"
            } else if let next = a.nextStopName {
                return "다음 \(next)"
            } else if let eta = a.etaMinutes {
                return "약 \(eta)분"
            } else {
                return nil
            }
        }()
        bubbleLabel.text = text
        bubble.isHidden = (text == nil)
        setNeedsLayout(); layoutIfNeeded()
    }
}


// 정류장=빨강 / 버스=파랑 클러스터
final class ClusterView: MKAnnotationView {
    private let countLabel = UILabel()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        layer.cornerRadius = 17
        countLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: topAnchor),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let cluster = annotation as? MKClusterAnnotation {
            countLabel.text = "\(cluster.memberAnnotations.count)"
            let isStopCluster = cluster.memberAnnotations.contains { $0 is BusStopAnnotation }
            backgroundColor = (isStopCluster ? UIColor.systemRed : UIColor.systemBlue).withAlphaComponent(0.9)
        }
    }
}

// MARK: - Tracking helpers
struct BusTrack {
    var prevLoc: CLLocationCoordinate2D?
    var prevAt: Date?
    var lastLoc: CLLocationCoordinate2D
    var lastAt: Date
    var speedMps: Double = 0
    var dirUnit: (x: Double, y: Double)? = nil

    mutating func updateKinematics() {
        guard let p = prevLoc, let _ = prevAt else { speedMps = 0; dirUnit = nil; return }
        let v = GeoUtil.deltaMeters(from: p, to: lastLoc)
        let dt = max(0.01, lastAt.timeIntervalSince(prevAt!))
        speedMps = v.dist / dt
        if v.dist > 0.5 { dirUnit = (x: v.dx / v.dist, y: v.dy / v.dist) } else { dirUnit = nil }
    }

    func predicted(at t: Date) -> CLLocationCoordinate2D {
        guard let p = prevLoc, let pa = prevAt else { return lastLoc }
        let dt = max(0, lastAt.timeIntervalSince(pa))
        let nowDt = max(0, t.timeIntervalSince(lastAt))
        let step = GeoUtil.deltaMeters(from: p, to: lastLoc).dist
        if dt < 0.5 || step < 0.5 { return lastLoc }

        let mLat = GeoUtil.metersPerDegLat(at: lastLoc.latitude)
        let mLon = GeoUtil.metersPerDegLon(at: lastLoc.latitude)
        let speed = step / dt
        let fwd = speed * nowDt

        let v = GeoUtil.deltaMeters(from: p, to: lastLoc)
        let ux = v.dx / max(0.001, v.dist)
        let uy = v.dy / max(0.001, v.dist)

        let dLat = (fwd * uy) / mLat
        let dLon = (fwd * ux) / mLon
        return .init(latitude: lastLoc.latitude + dLat, longitude: lastLoc.longitude + dLon)
    }

    func coastPredict(at t: Date, decay: Double, minSpeed: Double) -> CLLocationCoordinate2D {
        guard let p = prevLoc, let pa = prevAt else { return lastLoc }
        let base = GeoUtil.deltaMeters(from: p, to: lastLoc)
        let baseDt = max(0.01, lastAt.timeIntervalSince(pa))
        let baseV  = base.dist / baseDt
        let dt = max(0, t.timeIntervalSince(lastAt))
        let v = max(minSpeed, baseV * pow(decay, dt))
        if v < minSpeed { return lastLoc }

        let ux = base.dx / max(0.001, base.dist)
        let uy = base.dy / max(0.001, base.dist)
        let forward = v * dt

        let mLat = GeoUtil.metersPerDegLat(at: lastLoc.latitude)
        let mLon = GeoUtil.metersPerDegLon(at: lastLoc.latitude)
        let dLat = (forward * uy) / mLat
        let dLon = (forward * ux) / mLon
        return .init(latitude: lastLoc.latitude + dLat, longitude: lastLoc.longitude + dLon)
    }
}

// MARK: - ViewModel
@MainActor
final class MapVM: ObservableObject {
    @Published var stops: [BusStop] = []
    @Published var buses: [BusLive] = []
    @Published var followBusId: String?
    private var reloadInFlight = false

@MainActor private var stopsInFlight: Task<[BusStop], Error>?

    // 게이트/진행도 히스테리시스용 상태
    private var lastNextStopIndexByBusId: [String: Int] = [:]
    private var lastProgressSByBusId:    [String: Double] = [:]
    private var passStreakByBusId:       [String: Int] = [:]
    // MapVM 안에 추가
    private var lastETAMinByBusId: [String: Int] = [:]
    // MapVM 안에 추가
    private var lastSByBusId: [String: Double] = [:]        // 마지막 진행거리 s
    private var lastStopIdByBusId: [String: String] = [:]   // 마지막으로 고른 nextStop


    // MapVM 프로퍼티에 추가
    // routeNo -> (숫자)routeId 캐시 (국토부 메타용)
    private var numericRouteIdByRouteNo: [String: String] = [:]

    // routeId(숫자 or DJB) -> routeNo 역방향 캐시 (follow/메타 추적용)
    private var routeNoByRouteId: [String: String] = [:]


    // MapVM 안
    private var reloadTask: Task<Void, Never>?
    // MapVM 안에 추가
    private var lastPredictedStopId: [String: String] = [:]   // busId -> stopId

    // MapVM 안에 추가
    private var routeIdByRouteNo: [String: String] = [:]          // 이번 회차 도출된 매핑
    private var lastKnownRouteIdByRouteNo: [String: String] = [:] // 히스토리 캐시(신호등/야간 대비)



    // 유령 파라미터
    private let STALE_GRACE_SEC: TimeInterval = 45
    private let COAST_MIN_SPEED: Double = 0.3
    private let COAST_DECAY_PER_SEC: Double = 0.92
    private var routeNoById: [String: String] = [:]

    private let api = BusAPI()
    private var lastRegion: MKCoordinateRegion?
    private var lastReloadAt: Date = .distantPast
    private var regionTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var latestTopArrivals: [ArrivalInfo] = []
    private var isRefreshing = false
    
    // MapVM 안
    private var lastStopRefreshCenter: CLLocationCoordinate2D?
    private let stopQueryRadiusMeters: CLLocationDistance = 500          // 보여줄 반경 정보(개념적)
    private let centerShiftTriggerMeters: CLLocationDistance = 200       // 재조회 트리거 임계치(사용자 드래그)
    private let centerShiftTriggerWhenFollow: CLLocationDistance = 120   // 재조회 트리거 임계치(팔로우 중)


    // smoothing / snapping
    private var tracks: [String: BusTrack] = [:]
    private let maxStepMeters: CLLocationDistance = 300
    private let emaAlpha: Double = 0.35
    private let snapRadius: CLLocationDistance = 18
    private let dwellSec: TimeInterval = 15
    private var dwellUntil: [String: Date] = [:]
    // MapVM 프로퍼티에 추가
    private var kfByBusId: [String: KF1D.State] = [:]
    private var kf = KF1D()
    // MapVM 클래스 맨 위 @Published 모음 근처에 추가
    @Published var stickToFollowedBus: Bool = false   // 팔로우 시 자동 재센터링 여부 (기본: 꺼짐)

    
    // MapVM 안에 추가
    private var lastETA: [String: (eta: Int, at: Date)] = [:]
    // MapVM 프로퍼티 (캐시)
    private var routeStopsByRouteId: [String: [BusStop]] = [:]
    // ✅ epoch 게이팅
       private var epochCounter: UInt64 = 0
       private var latestAppliedEpoch: UInt64 = 0
    // MapVM.swift

    // MapVM.swift (클래스 맨 위 @Published 모음 근처)
    // MapVM 내부에 추가

    @Published var futureRouteCoords: [CLLocationCoordinate2D] = []   // ▶ 미래(앞으로 갈) 경로
    @Published var highlightedStopId: String?                         // ▶ 노란 하이라이트 정류장

    // MapVM 안 (프로퍼티들 근처)
    @Published var futureRouteVersion: Int = 0
    
    // 현재 좌표와 (가능하면) 추정 진행방향으로 임시 빨간선(직선) 그리기
    func setTemporaryFutureRouteFromBus(busId: String, coordinate: CLLocationCoordinate2D, meters: Double = 1200) {
        // tracks는 MapVM 내부에 private이지만, 여기선 접근 가능
        let tr = tracks[busId]
        setTemporaryFutureRoute(from: coordinate, using: tr, meters: meters)
    }
    // MapVM.swift 맨 위 근처에 타입 추가
    

    // MapVM 안에 메서드 추가
    /// 팔로우 중 버스의 앞으로 최대 N개 정류장 + ETA(분) (디버그 로그 강화)
    // MapVM
    func upcomingStops(for busId: String, maxCount: Int = 7) -> [UpcomingStopETA] {
        // 0) live
        guard let live = buses.first(where: { $0.id == busId }) else { return [] }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)

        // 1) meta 경로
        let routeNo = routeNoById[busId] ?? live.routeNo
        let ridRaw  = routeIdByRouteNo[routeNo] ?? lastKnownRouteIdByRouteNo[routeNo] ?? ""
        let ridEff  = numericRouteIdByRouteNo[routeNo] ?? numericRouteId(from: ridRaw) ?? ridRaw

        if let meta = routeMetaById[ridEff],
           meta.shape.count >= 2, meta.shape.count == meta.cumul.count,
           let prj = projectOnRoute(here, shape: meta.shape, cumul: meta.cumul) {

            let stopS = meta.stopS
            let routeStops = routeStopsByRouteId[ridEff] ?? routeStopsByRouteId[ridRaw] ?? []
            guard !stopS.isEmpty, stopS.count == routeStops.count else {
                return upcomingStopsDirectionalFallback(for: busId, maxCount: maxCount)
            }

            let startIdx = max(0, stopS.firstIndex(where: { $0 > prj.s }) ?? (stopS.count - 1))
            let vObs = max(0.1, tracks[busId]?.speedMps ?? 0)
            let vForETA = min(25.0, max(1.5, vObs))

            var out: [UpcomingStopETA] = []
            var lastETAmin: Int = live.etaMinutes ?? max(0, Int((((stopS[startIdx]-prj.s)/vForETA)/60.0).rounded()))
            let end = min(routeStops.count, startIdx + maxCount)

            for j in startIdx..<end {
                let remainS = max(0, stopS[j] - prj.s)
                var etaSec = Int(remainS / vForETA)
                if vObs < 1.2 && remainS < 25 { etaSec = 0 }
                var etaMin = max(0, Int((Double(etaSec)/60.0).rounded(.toNearestOrEven)))
                etaMin = max(etaMin, lastETAmin)
                lastETAmin = etaMin
                let stop = routeStops[j]
                out.append(.init(id: stop.id, name: stop.name, etaMin: etaMin))
            }
            return out
        }

        // 2) 메타가 없으면 방향기반 폴백
        return upcomingStopsDirectionalFallback(for: busId, maxCount: maxCount)
    }
    // MapVM
    @Published private(set) var upcomingTick: Int = 0

    private var knownStopsIndex: [String: BusStop] = [:]   // 전역 캐시(지도에 안 뿌림)
    private var aheadPrefetchInFlight: Set<String> = []    // 중복 프리페치 방지
    private var aheadPrefetchCooldown: [String: Date] = [:]// 너무 잦은 프리페치 쿨다운

    // MapVM
    private func prefetchStopsAhead(for busId: String, hops: Int = 6, stepMeters: Double = 400) async {
        // 쿨다운/중복 가드
        let now = Date()
        if aheadPrefetchInFlight.contains(busId) { return }
        if let until = aheadPrefetchCooldown[busId], until > now { return }
        aheadPrefetchInFlight.insert(busId)
        defer { aheadPrefetchInFlight.remove(busId) }

        guard let live = buses.first(where: { $0.id == busId }),
              let tr = tracks[busId], let dir = tr.dirUnit else { return }

        let lat0 = live.lat, lon0 = live.lon
        let cosLat = cos(lat0 * .pi/180)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cosLat

        var newly: [BusStop] = []
        for i in 1...hops {
            let dist = Double(i) * stepMeters
            // dir(x,y)는 미터 기준 단위벡터임: 이를 위경도로 투영
            let dLat = (dir.y * dist) / mPerDegLat
            let dLon = (dir.x * dist) / mPerDegLon
            let lat = lat0 + dLat
            let lon = lon0 + dLon

            // MOTIE 근접정류장 API 재사용
            if let arr = try? await api.fetchStops(lat: lat, lon: lon), !arr.isEmpty {
                newly.append(contentsOf: arr)
            }
        }

        if !newly.isEmpty {
            await MainActor.run {
                self.integrateKnownStops(newly)
                self.upcomingTick &+= 1           // ✅ 패널 리렌더 트리거
            }
        } else {
            // 너무 자주 빈손이면 60초 쿨다운
            aheadPrefetchCooldown[busId] = Date().addingTimeInterval(60)
        }
    }

    
    // MapVM
    private func upcomingStopsDirectionalFallback(for busId: String, maxCount: Int) -> [UpcomingStopETA] {
        guard let live = buses.first(where: { $0.id == busId }) else { return [] }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)
        guard let tr = tracks[busId], let dir = tr.dirUnit else { return [] }

        // ✅ 화면근처(vm.stops) + 전역캐시(knownStopsIndex) 둘 다 사용
        let catalog: [BusStop] = {
            var dict = [String: BusStop]()
            for s in stops { dict[s.id] = s }
            for s in knownStopsIndex.values { dict[s.id] = s }
            return Array(dict.values)
        }()

        // 필터 파라미터: 범위를 넉넉히(최대 3.5km 전방, 측면 180m)
        let aheadMinProj: Double = 8
        let aheadMaxProj: Double = 3500
        let lateralMax: Double  = 180

        let vObs  = max(0.1, tr.speedMps)
        let vForE = max(1.5, min(25.0, vObs))

        struct Cand { let stop: BusStop; let proj: Double; let lateral: Double; let dist: Double }
        let cands: [Cand] = catalog.map { s in
            let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: s.lat, longitude: s.lon))
            let proj = v.dx*dir.x + v.dy*dir.y
            let lat  = abs(-v.dy*dir.x + v.dx*dir.y)
            return Cand(stop: s, proj: proj, lateral: lat, dist: v.dist)
        }
        .filter { $0.proj >= aheadMinProj && $0.proj <= aheadMaxProj && $0.lateral <= lateralMax }
        .sorted { $0.proj < $1.proj }

        var out: [UpcomingStopETA] = []
        var lastETA = live.etaMinutes ?? 0
        for c in cands.prefix(maxCount) {
            var etaSec = Int(c.proj / vForE)
            if vObs < 1.2 && c.dist < 25 { etaSec = 0 }
            var etaMin = max(0, Int((Double(etaSec)/60.0).rounded(.toNearestOrEven)))
            etaMin = max(etaMin, lastETA)
            lastETA = etaMin
            out.append(.init(id: c.stop.id, name: c.stop.name, etaMin: etaMin))
        }

        // ✅ 모자라면 즉시 전방 프리페치 비동기 가동(결과 들어오면 패널 자동 업데이트)
        if out.count < maxCount {
            Task { await self.prefetchStopsAhead(for: busId) }
        }

        return out
    }






    // routeNo -> routeId 공개 래퍼 (내부용)
    func routeId(forRouteNo routeNo: String) -> String? {
        return resolveRouteId(for: routeNo)   // 원래 private인 함수에 얇은 포장
    }

    // MapVM 안에 추가
    /// 누적거리 테이블 cumul에서, s보다 작거나 같은 마지막 버텍스 인덱스(클램프) 반환
    private func vertexIndex(forS s: Double, in cumul: [Double]) -> Int {
        guard !cumul.isEmpty else { return 0 }
        if s <= cumul[0] { return 0 }
        if s >= cumul.last! { return max(0, cumul.count - 1) }

        var lo = 0, hi = cumul.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1
            if cumul[mid] <= s { lo = mid } else { hi = mid }
        }
        return lo // lo <= s < hi
    }
    
    // MapVM
    private var metaInFlight = Set<String>()              // 같은 노선 중복요청 방지
    private var metaCooldownUntil = [String: Date]()      // 실패 쿨다운
    // MapVM
    private func isCoolingDown(_ id: String) -> Bool {
        if let until = metaCooldownUntil[id] { return until > Date() }
        return false
    }
    private func startCooldown(_ id: String, minutes: Int = 15) {
        metaCooldownUntil[id] = Date().addingTimeInterval(Double(minutes) * 60)
    }
    private func clearCooldown(_ id: String) { metaCooldownUntil[id] = nil }

    // MapVM 안에 교체(기존 setFutureRoute... 대체)
    /// 현재 사영점(prj)에서 '다음 정류장(nextIdx)' → 그다음 정류장… 순으로,
    // 미래 경로를 정류장들로 이어서 생성
    // MapVM 안 (기존 futureRouteCoords 사용)
    // MapVM 안 (기존 메서드 교체)
    func setFutureRouteByStops(
        meta: RouteMeta,
        from prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextIdx: Int,
        maxAheadStops: Int = 7,
        includeTerminal: Bool = true   // 필요하면 마지막 정류장 포함/제외 선택
    ) {
        // 시작점 = 현재 위치(경로 위 사영점)
        var coords: [CLLocationCoordinate2D] = [prj.snapped]

        // 경계 보정
        guard nextIdx < meta.stopCoords.count else {
            futureRouteCoords.removeAll()
            futureRouteVersion &+= 1
            return
        }

        // 다음 정류장부터 최대 N개만 이어 붙이기
        var end = min(meta.stopCoords.count - 1, nextIdx + maxAheadStops - 1)
        if !includeTerminal, end == meta.stopCoords.count - 1 {
            end = max(nextIdx, end - 1)
        }

        if nextIdx <= end {
            coords.append(contentsOf: meta.stopCoords[nextIdx...end])
        }

        // 너무 짧으면 지우기
        if coords.count >= 2 {
            futureRouteCoords = coords
        } else {
            futureRouteCoords.removeAll()
        }
        futureRouteVersion &+= 1
    }



    
    // MapVM 안에 추가
    // MapVM 안에 이미 만든 ensureAndDrawFutureRouteNow 를 아래로 교체
    func ensureAndDrawFutureRouteNow(for busId: String, routeNo: String, coord: CLLocationCoordinate2D) async {
        // 0) routeId 확보
        guard let rid = resolveRouteId(for: routeNo) else {
            print("⚠️ futureRoute: routeId not resolved for \(routeNo)")
            DispatchQueue.main.async { self.clearFutureRoute() }
            return
        }

        // 1) 메타 보장 (await)
        await ensureRouteMeta(routeId: rid)

        // 2) 캐시에서 메타 꺼내기
        guard var meta = routeMetaById[rid] else {
            print("⚠️ futureRoute: meta missing for rid=\(rid)")
            DispatchQueue.main.async { self.clearFutureRoute() }
            return
        }

        // 3) 무결성 보정: 길이 불일치면 즉시 재계산
        if meta.cumul.count != meta.shape.count {
            print("⚠️ futureRoute: cumul len \(meta.cumul.count) != shape len \(meta.shape.count) → rebuild")
            let rebuilt = buildCumul(meta.shape)
            meta = RouteMeta(shape: meta.shape,
                             cumul: rebuilt,
                             stopIds: meta.stopIds,
                             stopCoords: meta.stopCoords,
                             stopS: meta.stopS)
            routeMetaById[rid] = meta
        }
        print("🔎 meta check: shape=\(meta.shape.count) cumul=\(meta.cumul.count)")

        // 4) shape 검증 (2점 미만이면 폴백 불가)
        guard meta.shape.count >= 2 else {
            print("⚠️ futureRoute: shape too short (\(meta.shape.count)) → clear")
            DispatchQueue.main.async { self.clearFutureRoute() }
            return
        }
        print("🔎 meta check: shape=\(meta.shape.count) cumul=\(meta.cumul.count)")

        // 5) 사영 시도
        if let prj = projectOnRoute(coord, shape: meta.shape, cumul: meta.cumul) {
            setFutureRoute(shape: meta.shape, fromSeg: prj.seg, fromPoint: prj.snapped)
            print("✅ futureRoute: set \(futureRouteCoords.count) pts (seg=\(prj.seg))")
        } else {
            // 6) 스냅 실패 → 'shape 전체'로 폴백(빨간 선이라도 보이게)
            print("⚠️ futureRoute: projectOnRoute failed → fallback to full shape")
            DispatchQueue.main.async {
                self.futureRouteCoords = meta.shape
                self.futureRouteVersion &+= 1
            }
        }
    }


    func clearFutureRoute() {
        futureRouteCoords.removeAll()
        futureRouteVersion &+= 1
    }

    /// 현재 사영 위치(prj.snapped)에서부터 노선 끝까지 라인 구성
    private func setFutureRoute(shape: [CLLocationCoordinate2D],
                                fromSeg seg: Int,
                                fromPoint snapped: CLLocationCoordinate2D) {
        guard !shape.isEmpty else { return }

        var coords: [CLLocationCoordinate2D] = []
        coords.append(snapped)

        // seg 이후의 shape 포인트들을 이어붙임
        let start = max( seg + 1, 0 )
        if start < shape.count {
            coords.append(contentsOf: shape[start..<shape.count])
        }

        // 너무 짧으면 무시
        if coords.count < 2 { futureRouteCoords = []; futureRouteVersion &+= 1; return }

        futureRouteCoords = coords
        futureRouteVersion &+= 1
    }

    // MapVM 안에 넣기(기존 setFutureRoute / updateFutureRouteIfFollowed 를 대체)

    // prj.s(현재 진행 s)에서부터 stopS[nextIdx], stopS[nextIdx+1] ... 순서로
    // meta.shape의 포인트들을 잘라 붙이며 경로를 만든다.
    private func buildFutureRouteStopToStop(meta: RouteMeta,
                                            prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
                                            nextIdx: Int) -> [CLLocationCoordinate2D] {
        guard !meta.shape.isEmpty, meta.shape.count == meta.cumul.count,
              !meta.stopS.isEmpty, meta.stopS.count == meta.stopIds.count else { return [] }

        var coords: [CLLocationCoordinate2D] = []
        coords.append(prj.snapped)                 // 시작: 현재 사영점
        var curS = prj.s                           // 현재 누적 s의 기준점
        var startSeg = prj.seg                     // 다음 shape 포인트 시작 인덱스

        // 구간별로: (curS -> stopS[i]) 까지 shape 포인트를 붙이고, 마지막에 정류장 좌표를 추가
        for i in nextIdx ..< meta.stopS.count {
            let targetS = meta.stopS[i]
            if targetS <= curS { continue }        // 방어적

            // shape에서 curS 이후 ~ targetS 이하인 포인트만 추가
            // seg 힌트를 가진 상태라 비용 적음
            var j = max(0, startSeg + 1)
            while j < meta.cumul.count && meta.cumul[j] <= targetS {
                if meta.cumul[j] > curS { coords.append(meta.shape[j]) }
                j += 1
            }

            // 마지막에 "정류장 좌표"를 꼭 찍어 준다(시각적으로 직관적)
            coords.append(meta.stopCoords[i])

            // 다음 루프를 위해 기준 갱신
            curS = targetS
            startSeg = max(startSeg, j - 1)
        }

        // 너무 짧으면 무시
        return coords.count >= 2 ? coords : []
    }

    // 팔로우 중일 때만 VM state에 반영
    // MapVM 안의 기존 메서드 교체
    // MapVM 내부 (기존 updateFutureRouteIfFollowed 교체/확장)
    private func updateFutureRouteIfFollowed(
        busId: String,
        meta: RouteMeta,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextIdx: Int
    ) {
        guard followBusId == busId else { return }
        let coords = buildFutureRouteStopByStop(meta: meta, prj: prj, nextStartIdx: nextIdx)
        guard coords.count >= 2 else {
            futureRouteCoords = []; futureRouteVersion &+= 1
            return
        }
        futureRouteCoords = coords
        futureRouteVersion &+= 1
    }


    // 탭 직후 즉시 그릴 때(메타가 이미 있을 때)
    // MapVM 안의 기존 메서드 교체
    /// 선택 직후(팔로우 시작 직후) 즉시 빨간선 미리 그리기
    // 탭 직후 즉시 빨간선(정류장 단위) 그리기
    func trySetFutureRouteImmediately(for bus: BusAnnotation) {
        guard
            let rid  = resolveRouteId(for: bus.routeNo),
            let meta = routeMetaById[rid],
            let prj  = projectOnRoute(bus.coordinate, shape: meta.shape, cumul: meta.cumul)
        else {
            print("⚠️ futureRoute: meta or projection missing")
            return
        }

        // prj.s 이후의 첫 정류장을 다음으로
        let nextIdx = max(0, meta.stopS.firstIndex(where: { $0 > prj.s }) ?? (meta.stopS.count - 1))

        // ⬇️ 정류장 좌표만 이어서 빨간 라인
        setFutureRouteByStops(meta: meta, from: prj, nextIdx: nextIdx, maxAheadStops: 7, includeTerminal: false)
    }


    
    
    
    
    // MapVM.swift 안
    private func buildFutureRoute(meta: RouteMeta,
                                  prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double)
    ) -> [CLLocationCoordinate2D] {
        // 현재 스냅된 지점부터 다음 버텍스 ~ 종점까지 이어붙이기
        var coords: [CLLocationCoordinate2D] = [prj.snapped]
        let start = min(prj.seg + 1, meta.shape.count)   // 다음 버텍스부터
        if start < meta.shape.count {
            coords.append(contentsOf: meta.shape[start...])
        }
        return coords
    }

    /// 외부에서 지울 때 사용
  

    
    // MapVM 안 (private 메서드 섹션)
    private func setFutureRoute(from segIndex: Int,
                                snapped: CLLocationCoordinate2D,
                                meta: RouteMeta) {
        var coords: [CLLocationCoordinate2D] = [snapped]
        let i = max(0, min(segIndex + 1, meta.shape.count))   // 현 위치 이후부터
        if i < meta.shape.count {
            coords.append(contentsOf: meta.shape[i...])
        }
        // 너무 가까운 중복점 제거(옵션)
        if coords.count >= 2 {
            var cleaned: [CLLocationCoordinate2D] = [coords[0]]
            for c in coords.dropFirst() {
                let d = CLLocation(latitude: cleaned.last!.latitude, longitude: cleaned.last!.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                if d >= 2 { cleaned.append(c) }
            }
            futureRouteCoords = cleaned
        } else {
            futureRouteCoords = coords
        }
        futureRouteVersion &+= 1
    }
    // MapVM 안
    func highlightedBusStop() -> BusStop? {
        guard let sid = highlightedStopId,
              let fid = followBusId,
              let rno = routeNoById[fid],
              let rid = resolveRouteId(for: rno),
              let arr = routeStopsByRouteId[rid] else { return nil }
        return arr.first { $0.id == sid }
    }

    /// 현재(사영점)에서 노선 shape의 끝까지를 빨간 선으로 쓰기 위한 좌표 배열을 만든다.
    func updateFutureRoute(
        for busId: String,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        meta: RouteMeta
    ) {
        var coords: [CLLocationCoordinate2D] = []
        coords.append(prj.snapped) // 현재 위치(경로 위 사영점) 포함

        if prj.seg + 1 < meta.shape.count {
            coords.append(contentsOf: meta.shape[(prj.seg + 1)...])
        }

        // 메인스레드 반영
        DispatchQueue.main.async { [weak self] in
            self?.futureRouteCoords = coords
        }
    }


    func updateHighlightStop(for bus: BusLive) {
        highlightedStopId = bus.nextStopName != nil
            ? stops.first(where: { $0.name == bus.nextStopName })?.id
            : nil
    }

    // MapVM 내부에 추가
    // MapVM
    func futureRoutePolyline(for busId: String) -> MKPolyline? {
        guard let live = buses.first(where: { $0.id == busId }) else { return nil }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)

        let routeNo = routeNoById[busId] ?? live.routeNo
        guard let routeId = resolveRouteId(for: routeNo),
              let meta = routeMetaById[routeId],
              meta.shape.count >= 2,
              meta.shape.count == meta.cumul.count else {
            return nil
        }

        if let prj = projectOnRoute(here, shape: meta.shape, cumul: meta.cumul) {
            var coords: [CLLocationCoordinate2D] = []
            coords.append(prj.snapped)
            let nextIdx = max(0, min(prj.seg + 1, meta.shape.count - 1))
            coords.append(contentsOf: meta.shape[nextIdx...])
            let line = MKPolyline(coordinates: coords, count: coords.count)
            line.title = "busFuture"
            return line
        } else {
            let line = MKPolyline(coordinates: meta.shape, count: meta.shape.count)
            line.title = "busFuture"
            return line
        }
    }


    let trail = BusTrailStore()
        @Published var trailVersion: Int = 0      // 오버레이 갱신 트리거

        func startTrail(for busId: String, seed: CLLocationCoordinate2D?) {
            trail.start(id: busId, seed: seed); trailVersion &+= 1
        }
        func stopTrail() { trail.stop(); trailVersion &+= 1 }
    // MapVM 안에 추가
    /// ETA(분)과 다음 정류장 s_stop을 이용해 s_eta 관측치와 분산 R을 만든다.
    private func etaToSObservation(nextStopS: Double, etaMinutes: Int, vPrior: Double) -> (z: Double, R: Double) {
        let t = max(0.0, Double(etaMinutes) * 60.0)
        let v = max(1.5, min(vPrior, 25.0))   // 지나친 낙관/비관 방지
        // d_rem ≈ v * t  →  s_eta = s_stop - d_rem
        let z = nextStopS - v * t
        // ETA 신뢰도: 시간이 멀수록, 혼잡구간일수록 분산 크게
        let baseVar = 80.0 * 80.0             // 80m 표준편차 가정
        let scale = 1.0 + min(t/240.0, 2.0)   // 0~>4분 이상이면 가중 하향
        let R = baseVar * scale
        return (z, R)
    }

    
    // MapVM 안에 추가
    private struct KF1D {
        struct State { var s: Double; var v: Double; var P: simd_double2x2 }
        // 공정잡음(가감 가능)
        var q_s: Double = 1.0      // s 공정잡음( m^2 / s )
        var q_v: Double = 0.8      // v 공정잡음( (m/s)^2 )
        var v_max: Double = 30.0   // 물리적 속도 상한(도시버스~)

        mutating func predict(_ x: inout State, dt: Double) {
            // x = F x, P = FPFᵀ + Q
            let F = simd_double2x2([SIMD2(1, dt), SIMD2(0, 1)])
            let Q = simd_double2x2([SIMD2(q_s*dt, 0), SIMD2(0, q_v*dt)])
            let sv = SIMD2(x.s, x.v)
            let svp = F * sv
            x.s = svp[0]
            x.v = min(max(svp[1], 0), v_max)
            x.P = F * x.P * F.transpose + Q
        }

        mutating func update(z: Double, R: Double, _ x: inout State) {
            // 관측 z = H x + r, H = [1, 0] (s만 관측)
            let H = SIMD2(1.0, 0.0)
            let HP = SIMD2( x.P[0,0], x.P[1,0] ) // P * Hᵀ (열)
            let S = H[0]*HP[0] + H[1]*HP[1] + R  // HPHᵀ + R (스칼라)
            let K = SIMD2(HP[0]/S, HP[1]/S)      // 칼만 이득(2x1)

            // 로버스트 허버 게이팅
            let y = z - x.s                       // 잔차
            let huber = 25.0                      // 임계(m)
            let yAdj: Double = abs(y) <= huber ? y : (huber * (y >= 0 ? 1 : -1))

            // 상태 업데이트
            x.s += K[0] * yAdj
            x.v = min(max(x.v + K[1] * yAdj, 0), v_max)

            // 공분산 업데이트: P = (I - K H) P
            var I = simd_double2x2(diagonal: SIMD2(1,1))
            let KH = simd_double2x2([SIMD2(K[0]*H[0], K[0]*H[1]),
                                     SIMD2(K[1]*H[0], K[1]*H[1])])
            x.P = (I - KH) * x.P
        }
    }

       // 읽기 전용 스냅샷 타입
       struct RouteSnapshot {
           let metaById: [String: RouteMeta]          // 이미 가지고 있는 타입
           let stopsByRouteId: [String: [BusStop]]
       }

       // 현재 보유 데이터로 스냅샷 만들기
       private func makeRouteSnapshot() -> RouteSnapshot {
           return RouteSnapshot(metaById: routeMetaById, stopsByRouteId: routeStopsByRouteId)
       }

       // 주어진 epoch 가 최신일 때만 상태 반영
       private func applyIfCurrent(epoch: UInt64, _ apply: () -> Void) {
           if epoch >= latestAppliedEpoch {
               latestAppliedEpoch = epoch
               apply()
           }
       }

       // (선택) 팔로우 시작 시 노선 프리페치
       func prefetchFollowedRouteIfNeeded(routeId: String) {
           Task { [weak self] in
               guard let self else { return }
               if self.routeMetaById[routeId] == nil {
                   try? await self.ensureRouteMeta(routeId: routeId)
               }
           }
       }
    // MARK: Route meta & matcher cache
    struct RouteMeta {
        let shape: [CLLocationCoordinate2D]  // 폴리라인 점열
        let cumul: [Double]                  // 각 점까지 누적거리(미터)
        let stopIds: [String]
        let stopCoords: [CLLocationCoordinate2D]
        let stopS: [Double]                  // 각 정류장 투영 진행거리 s(미터)
    }
    private var routeMetaById: [String: RouteMeta] = [:]

    /// 경로 진행도 s 기반 '엄격' 다음 정류장 판정
    /// - busId: 차량 식별(히스테리시스 상태 유지용)
    /// - progressS: 경로 폴리라인에 사영한 현재 진행거리(미터)
    /// - routeStops: 노선의 정류장 배열
    /// - stopS: 각 정류장의 경로상 거리 s 배열 (routeStops와 같은 순서, shape/cumul로 만든 값)
    /// - lateral: 경로로부터의 횡오차(미터) - 너무 크면 판정을 급변시키지 않음
    /// 노선 기반 "다음 정류장" 엄격 판정
    /// - busId: 차량 고유 id
    /// - progressS: 경로에 사영된 현재 진행거리 s (미터)
    /// - routeStops: 노선상의 정류장 배열
    /// - stopS: 각 정류장의 경로상 누적거리(s) (routeStops와 인덱스 일치)
    /// - lateral: 경로로부터의 측방 오차(미터)
    // MapVM 안
    private func nextStopFromRouteStrict(
        busId: String,
        progressS: Double,
        routeStops: [BusStop],
        stopS: [Double],
        lateral: Double
    ) -> BusStop? {
        guard !routeStops.isEmpty, routeStops.count == stopS.count else { return nil }

        // 1) s 역행 억제(최대 20m만 허용)
        let sPrev = lastSByBusId[busId] ?? progressS
        let sNow  = max(progressS, sPrev - 20)

        // 2) 게이트
        let AHEAD_GATE = max(18.0, min(50.0, 12.0 + 0.35 * lateral))
        let lastIdx: Int? = {
            guard let sid = lastStopIdByBusId[busId] else { return nil }
            return routeStops.firstIndex(where: { $0.id == sid })
        }()

        // 3) sNow + 게이트를 넘는 첫 정류장을 후보로
        var candIdx: Int? = nil
        for i in 0..<stopS.count {
            if stopS[i] > sNow + AHEAD_GATE { candIdx = i; break }
        }

        // 4) 히스테리시스(한 정거장씩만 전진)
        if let li = lastIdx, let ci = candIdx, ci > li + 1 {
            candIdx = li + 1
        }

        // 5) 채택/유지
        if let ci = candIdx {
            let chosen = routeStops[ci]
            lastSByBusId[busId] = max(sPrev, sNow)
            lastStopIdByBusId[busId] = chosen.id
            return chosen
        } else if let li = lastIdx {
            lastSByBusId[busId] = max(sPrev, sNow)
            return routeStops[li]
        } else {
            lastSByBusId[busId] = max(sPrev, sNow)
            return nil
        }
    }


    // 폴리라인 누적거리 테이블 생성
    private func buildCumul(_ pts: [CLLocationCoordinate2D]) -> [Double] {
        guard !pts.isEmpty else { return [] }
        var out: [Double] = [0]
        for i in 1..<pts.count {
            let d = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
                .distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
            out.append(out.last! + d)
        }
        return out
    }

    // 점을 폴리라인에 사영(세그먼트 클램프). s=경로 진행거리, lateral=경로와의 수직거리
    private func projectOnRoute(_ p: CLLocationCoordinate2D,
                                shape: [CLLocationCoordinate2D],
                                cumul: [Double]) -> (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double)? {
        guard shape.count >= 2, shape.count == cumul.count else { return nil }
        var best: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double)? = nil

        for i in 0..<(shape.count-1) {
            let a = shape[i], b = shape[i+1]
            let va = GeoUtil.deltaMeters(from: a, to: p)
            let ab = GeoUtil.deltaMeters(from: a, to: b)
            let abLen2 = max(1e-6, ab.dx*ab.dx + ab.dy*ab.dy)
            var t = (va.dx*ab.dx + va.dy*ab.dy) / abLen2
            t = max(0, min(1, t))
            let px = ab.dx * t, py = ab.dy * t
            let snapped = CLLocationCoordinate2D(latitude: a.latitude + (py/GeoUtil.metersPerDegLat(at: a.latitude)),
                                                 longitude: a.longitude + ((px)/GeoUtil.metersPerDegLon(at: a.latitude)))
            let lateral = hypot(va.dx - px, va.dy - py)
            let s = cumul[i] + sqrt(min(abLen2, ab.dx*ab.dx + ab.dy*ab.dy)) * t
            if best == nil || lateral < best!.lateral {
                best = (snapped, s, i, lateral)
            }
        }
        return best
    }

    // 정류장 좌표들을 경로 s로 변환
    private func stopsProjectedS(_ stops: [BusStop], shape: [CLLocationCoordinate2D], cumul: [Double]) -> [Double] {
        stops.map { s in
            let p = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
            if let prj = projectOnRoute(p, shape: shape, cumul: cumul) { return prj.s }
            return .infinity
        }
    }
    // MapVM 안에 추가: 폴백(임시) 미래 경로 — 현 위치에서 진행방향으로 N미터를 직선으로 그려줌
    func setTemporaryFutureRoute(from coord: CLLocationCoordinate2D, using track: BusTrack?, meters: Double = 1200) {
        var coords: [CLLocationCoordinate2D] = [coord]
        if let tr = track, let dir = tr.dirUnit {
            let mLat = GeoUtil.metersPerDegLat(at: coord.latitude)
            let mLon = GeoUtil.metersPerDegLon(at: coord.latitude)
            let dLat = (meters * dir.y) / mLat
            let dLon = (meters * dir.x) / mLon
            let p2 = CLLocationCoordinate2D(latitude: coord.latitude + dLat, longitude: coord.longitude + dLon)
            coords.append(p2)
        } else {
            // 방향 없으면 화면 위쪽으로라도 짧게
            let mLat = GeoUtil.metersPerDegLat(at: coord.latitude)
            let p2 = CLLocationCoordinate2D(latitude: coord.latitude + (meters / mLat), longitude: coord.longitude)
            coords.append(p2)
        }
        DispatchQueue.main.async { [weak self] in
            self?.futureRouteCoords = coords
            self?.futureRouteVersion &+= 1
        }
    }

    // MapVM 안에 추가: 메타 재시도(지수 백오프)
    // MapVM
    // MapVM
    // MapVM
    @MainActor
    func ensureRouteMetaWithRetry(routeId rawRouteId: String, routeNo: String? = nil) {
        // 메인 액터에서 in-flight / 쿨다운 가드
        if isCoolingDown(rawRouteId) { return }
        if metaInFlight.contains(rawRouteId) { return }
        metaInFlight.insert(rawRouteId)

        // 현재 액터 컨텍스트 상속 (detached 금지)
        Task { [weak self] in
            guard let self else { return }

            let backoff: [Double] = [0.0, 2.0, 5.0]   // 초 단위
            var succeeded = false

            for (i, delay) in backoff.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                let ok = await self.ensureRouteMetaOnce(rawRouteId: rawRouteId, routeNo: routeNo)
                if ok {                       // 성공 → 루프 종료 (return 금지)
                    succeeded = true
                    break
                }

                if i == backoff.indices.last { // 마지막 시도 실패 → 쿨다운
                    await self.startCooldown(rawRouteId, minutes: 15)
                    print("⚠️ ensureRouteMeta cooldown 15m for \(rawRouteId)")
                }
            }

            // 항상 마지막에 in-flight 제거 (메인 액터 hop)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.metaInFlight.remove(rawRouteId)
            }
        }
    }


    /// 기존 호출부용 오버로드: routeId만 주어졌을 때 routeNo를 역캐시에서 찾아서 넘겨줌
    // (호환용)
    // MapVM 안에 있던 ensureRouteMeta(routeId:)를 아래 두 개로 교체

    private func ensureRouteMeta(routeId: String) async {
        await ensureRouteMeta(routeId: routeId, routeNo: routeNoByRouteId[routeId])
    }

    private func ensureRouteMeta(routeId rawRouteId: String, routeNo: String?) async {
        // 캐시 히트면 끝
        if let m = routeMetaById[rawRouteId], m.shape.count >= 2, m.shape.count == m.cumul.count { return }
        if let no = routeNo, let num = numericRouteIdByRouteNo[no],
           let m2 = routeMetaById[num], m2.shape.count >= 2, m2.shape.count == m2.cumul.count {
            routeMetaById[rawRouteId] = m2
            return
        }

        // 1) 정류장 확보 (numeric → raw 순서로 시도)
        let (stops, usedId) = await fetchStopsForRoute(rawRouteId: rawRouteId, routeNo: routeNo)
        let idForCache = usedId ?? (numericRouteId(from: rawRouteId) ?? rawRouteId)

        // 2) 경로 시도 (숫자ID 우선)
        var shape: [CLLocationCoordinate2D] = []
        do {
            let tryId = numericRouteId(from: rawRouteId) ?? rawRouteId
            shape = try await api.fetchRoutePath(cityCode: CITY_CODE, routeId: tryId)
        } catch {
            shape = []
        }

        // 3) 폴백: shape이 없고 stops가 있으면 정류장 연결로 만든다
        if shape.count < 2, stops.count >= 2 {
            shape = stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }

        // 4) 최종 검사 및 저장(양쪽 키에 저장)
        let cumul = buildCumul(shape)
        guard shape.count >= 2, cumul.count == shape.count else {
            // 실패해도 캐시에 "빈 메타" 저장 안 함 (다음에 재시도)
            return
        }
        let stopS = stopsProjectedS(stops, shape: shape, cumul: cumul)
        let meta = RouteMeta(
            shape: shape, cumul: cumul,
            stopIds: stops.map { $0.id },
            stopCoords: stops.map { .init(latitude: $0.lat, longitude: $0.lon) },
            stopS: stopS
        )
        routeMetaById[idForCache] = meta
        routeMetaById[rawRouteId] = meta
        if let no = routeNo { if let num = numericRouteId(from: rawRouteId) { numericRouteIdByRouteNo[no] = num } }
    }


    // MapVM 안, private helpers 섹션
    /// 지역형 routeId("DJB30300128")에서 숫자만 추출 → "30300128"
    private func numericRouteId(from rid: String?) -> String? {
        guard let rid else { return nil }
        let digits = rid.filter { $0.isNumber }
        return digits.isEmpty ? nil : digits
    }



    // MapVM 안의 ensureRouteMeta(routeId:) 를 아래처럼 일부 보완
    /// 노선 메타 확보: 경로(shape) + 정류장(stopS) 계산
//    @MainActor
//    func ensureRouteMeta(routeId: String, routeNo: String) async {
//        // numeric 우선, 없으면 DJB 그대로
//        let effectiveId = numericRouteIdByRouteNo[routeNo] ?? routeId
//
//        // 이미 있으면 스킵
//        if routeMetaById[effectiveId] != nil { return }
//
//        do {
//            // 정류장 목록
//            let stops = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: effectiveId)
//
//            // 노선 경로 (shape)
//            var shape = try await api.fetchRoutePath(cityCode: CITY_CODE, routeId: effectiveId)
//
//            // shape이 너무 짧으면 정류장 좌표 fallback
//            if shape.count < 2, stops.count >= 2 {
//                print("⚠️ ensureRouteMeta: fallback to stops for \(effectiveId)")
//                shape = stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
//            }
//
//            // 누적 거리 배열 계산
//            let cumul = buildCumul(shape)
//            guard cumul.count == shape.count else {
//                print("⚠️ ensureRouteMeta: cumul mismatch for \(effectiveId)")
//                return
//            }
//
//            // 정류장 → shape상 좌표 매핑
//            let stopS: [Double] = stops.compactMap { s in
//                projectOnRoute(CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
//                               shape: shape, cumul: cumul)?.s
//            }
//
//            guard !stopS.isEmpty else {
//                print("⚠️ ensureRouteMeta: no stopS for \(effectiveId)")
//                return
//            }
//
//            // 캐싱
//            let meta = RouteMeta(shape: shape, cumul: cumul, stopS: stopS, stops: stops)
//            routeMetaById[effectiveId] = meta
//            print("✅ ensureRouteMeta: stored meta for \(effectiveId), shape=\(shape.count), stops=\(stops.count)")
//        } catch {
//            print("❌ ensureRouteMeta(\(effectiveId)) error: \(error)")
//        }
//    }

    // MapVM 안, private helpers 섹션
   

    
    // routeNo -> routeId 해석
    private func resolveRouteId(for routeNo: String) -> String? {
        if let id = routeIdByRouteNo[routeNo] { return id }
        if let id = lastKnownRouteIdByRouteNo[routeNo] { return id }
        // latestTopArrivals 안에서도 시도
        if let id = latestTopArrivals.first(where: { $0.routeNo == routeNo })?.routeId {
            routeIdByRouteNo[routeNo] = id
            lastKnownRouteIdByRouteNo[routeNo] = id
            return id
        }
        return nil
    }

    // 버스 선택 시: 해당 노선의 정류장 목록을 캐시에 로드
    func onBusSelected(_ bus: BusAnnotation) async {
        guard let rid = resolveRouteId(for: bus.routeNo) else { return }
        // 정류장/경로 메타 모두 보장
        await ensureRouteMeta(routeId: rid)
    }

    
    // MapVM 안에 추가: 노선 정류장 배열 기반으로 다음 정류장 추정
    /// 노선 정류장 배열 기반으로 "다음 정류장"을 엄격하게 계산.
    /// - 규칙:
    ///   1) 초기화: 가장 가까운 정류장 기준으로 진행방향을 보아 next 후보를 정함
    ///   2) 유지: 현재 next(J) 앞의 "게이트"(J를 지나는 수직선) 통과 전에는 J를 계속 유지
    ///   3) 통과: 버스가 J를 지나 다음 정류장 방향으로 proj >= passMargin 이면 J+1로 전환
    /// 경로 진행거리 s(미터)로 엄격하게 다음 정류장 결정.
    /// - gatePassMargin: J의 s를 기준으로 그 앞(+방향)으로 최소 몇 m 지나야 J+1로 전환할지
    /// 경로 진행거리 s(미터) 기반 "다음 정류장" (엄격 게이트 + 히스테리시스)
    /// - 규칙
    ///   • 절대 건너뛰기 금지(한 번에 +1만 가능)
    ///   • J 정류장 게이트(s[J] + margin)를 "연속 N회" 넘어서야 J+1 전환
    ///   • J에 근접(holdRadius)이면 무조건 J 유지
    ///   • s가 잠깐 앞섰다 다시 뒤로 가는 노이즈도 무시(진행 증가량 minAdvance 필요)
    private func nextStopFromRoute(
        busId: String,
        progressS s: Double,
        routeStops: [BusStop],
        stopS: [Double]
    ) -> BusStop? {

        guard routeStops.count == stopS.count, !routeStops.isEmpty, s.isFinite else { return nil }

        // 튜닝 파라미터
        let gateMargin: Double   = 18     // 게이트 통과 최소 오버슛 (m)
        let holdRadius: Double   = 55     // J 근접 시 무조건 유지 (m)
        let minAdvance: Double   = 6      // 샘플 간 최소 전진량이 있어야 유효 통과로 인정 (m)
        let neededStreak: Int    = 2      // 연속 통과 샘플 수(2번 연속 s>=gate + 전진)

        // 0) 초기 next 인덱스 정하기 (s 기준 "다가올" 정류장)
        func initialIndex(for s: Double) -> Int {
            // s 이상인 첫 정류장(다가올 정류장). 없으면 마지막.
            if let idx = stopS.firstIndex(where: { $0 >= s }) { return idx }
            return stopS.count - 1
        }

        var curIdx = lastNextStopIndexByBusId[busId] ?? initialIndex(for: s)
        curIdx = max(0, min(curIdx, stopS.count - 1))

        // 상태 읽기/업데이트용
        let lastS   = lastProgressSByBusId[busId] ?? s
        let deltaS  = s - lastS
        lastProgressSByBusId[busId] = s

        // 마지막 정류장이면 더 이동 불가
        if curIdx >= stopS.count - 1 {
            lastNextStopIndexByBusId[busId] = curIdx
            passStreakByBusId[busId] = 0
            return routeStops[curIdx]
        }

        // 현재 J, 다음 K
        let sJ = stopS[curIdx]
        let sK = stopS[curIdx + 1]

        // 1) J에 충분히 가까우면 J 고정 (GPS/신호등 오차 흡수)
        let distToJ = abs(sJ - s)
        if distToJ <= holdRadius {
            lastNextStopIndexByBusId[busId] = curIdx
            passStreakByBusId[busId] = 0
            return routeStops[curIdx]
        }

        // 2) 게이트 통과 판정: s가 sJ+margin 이상이고, 직전 대비 유의미하게 전진(minAdvance) 했을 때만 카운트
        let gate = sJ + gateMargin
        if s >= gate && deltaS >= minAdvance {
            passStreakByBusId[busId] = (passStreakByBusId[busId] ?? 0) + 1
        } else {
            // 한 번이라도 조건을 못 만족하면 스트릭 리셋(튀는 값 방지)
            passStreakByBusId[busId] = 0
        }

        // 3) 연속 N회 만족 시에만 +1 전환 (건너뛰기 불가 보장)
        if (passStreakByBusId[busId] ?? 0) >= neededStreak {
            curIdx = min(curIdx + 1, stopS.count - 1)
            passStreakByBusId[busId] = 0
        }

        // 4) 뒤로 가는 일은 허용하지 않음(노이즈로 s 감소해도 curIdx 유지)
        //    또한 s가 K를 훌쩍 넘었더라도 한 번에 +1만(다다음 방지)
        if curIdx < stopS.count - 1 {
            curIdx = min(curIdx, lastNextStopIndexByBusId[busId] ?? curIdx)
            curIdx = max(curIdx, lastNextStopIndexByBusId[busId] ?? curIdx) // 실질적으로 변화 없게 유지
        }

        lastNextStopIndexByBusId[busId] = curIdx
        return routeStops[curIdx]
    }


    // ETA 스무딩
    private func smoothETA(rawETA: Int?, busId: String, distToNextStop: Double?) -> Int? {
        guard let raw = rawETA else { return nil }
        let now = Date()

        // 멈춤-신호등 상황 완화: 정류장에서 멀리(>50m) + 느림일 때 증가율 제한
        let farFromStop = (distToNextStop ?? 9999) > 50
        let speed = tracks[busId]?.speedMps ?? 0
        let isSlow = speed < 1.0

        if isSlow && farFromStop, let prev = lastETA[busId] {
            // 30초당 +1분까지만 증가 허용, 감소는 즉시 반영
            if raw >= prev.eta {
                let dt = now.timeIntervalSince(prev.at)
                let allowedIncrease = Int(dt / 30.0) // 0,1,2...
                let capped = min(prev.eta + allowedIncrease, raw)
                lastETA[busId] = (capped, now)
                return capped
            } else {
                lastETA[busId] = (raw, now)
                return raw
            }
        } else {
            lastETA[busId] = (raw, now)
            return raw
        }
    }


    deinit { autoTask?.cancel(); regionTask?.cancel() }

    // MapVM 안
    private func metersBetween(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> CLLocationDistance {
        guard let a, let b else { return .greatestFiniteMagnitude }
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }

    
    // ⬇️ 이 메서드를 통째로 교체
    // MapVM
   private func shouldReload(for region: MKCoordinateRegion) -> Bool {
       let threshold: CLLocationDistance = (followBusId == nil) ? 180 : 120
       if lastStopRefreshCenter == nil {
           DBG.vm.log("🧭 shouldReload=YES (no last center)")
           return true
       }
       let moved = metersBetween(lastStopRefreshCenter, region.center)
       if moved >= threshold {
          
           return true
       }
       if let prev = lastRegion {
           let zoomDelta = abs(region.span.latitudeDelta - prev.span.latitudeDelta) / max(prev.span.latitudeDelta, 0.0001)
           if zoomDelta >= 0.20 {
                
               return true
           }
       } else {
           DBG.vm.log("🧭 shouldReload=YES (no last region)")
           return true
       }
       DBG.vm.log("🧭 shouldReload=NO")
       return false
   }



    // MapVM 안의 기존 ensureFollowGhost(...) 교체
    private func ensureFollowGhost(_ mergedById: inout [String: BusLive]) {
        guard let fid = followBusId, mergedById[fid] == nil, let tr = tracks[fid] else { return }

        let age = Date().timeIntervalSince(tr.lastAt)
        let dwellHolding = (dwellUntil[fid] ?? .distantPast) > Date()
        let maxGhostAge: TimeInterval = dwellHolding ? 3600 : 300
        guard age < maxGhostAge else { return }

        let pred = tr.coastPredict(at: Date().addingTimeInterval(0.6),
                                   decay: COAST_DECAY_PER_SEC, minSpeed: COAST_MIN_SPEED)

        var ghost = mergedById.values.first { $0.id == fid }
            ?? BusLive(id: fid, routeNo: routeNoById[fid] ?? "?", lat: pred.latitude, lon: pred.longitude, etaMinutes: nil, nextStopName: nil)

        ghost.lat = pred.latitude
        ghost.lon = pred.longitude

        let (ns, etaRaw) = nextStopAndETA(busId: fid, coord: pred, track: tr, fallbackByName: ghost.nextStopName)
        if let s = ns { ghost.nextStopName = s.name }
        let dist = ns.map { s in GeoUtil.deltaMeters(from: pred, to: .init(latitude: s.lat, longitude: s.lon)).dist }
        ghost.etaMinutes = smoothETA(rawETA: etaRaw, busId: fid, distToNextStop: dist)

        mergedById[fid] = ghost
    }


    // 진행방향 앞쪽 정류장 + ETA
    // MapVM 안의 기존 nextStopAndETA(...) 전체 교체
    private func nextStopAndETA(
        busId: String,
        coord: CLLocationCoordinate2D,
        track: BusTrack,
        fallbackByName: String?
    ) -> (BusStop?, Int?) {

        // 파라미터/가중치
        let searchRadius: Double = 320
        let aheadProjMin: Double = -8
        let lateralBias: Double = 2.2
        let switchMarginMeters: Double = 22
        let passBehindProj: Double = -18
        let keepSameIfNearMeters: Double = 60

        let here = coord
        let nearby = stops
            .map { stop -> (s: BusStop, dx: Double, dy: Double, dist: Double) in
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: stop.lat, longitude: stop.lon))
                return (stop, v.dx, v.dy, v.dist)
            }
            .filter { $0.dist < searchRadius }

        guard !nearby.isEmpty else {
            if let name = fallbackByName,
               let found = stops.first(where: { name.contains($0.name) || $0.name.contains(name) }) {
                let v = GeoUtil.deltaMeters(from: here, to: .init(latitude: found.lat, longitude: found.lon))
                let vObs = max(0.1, track.speedMps)
                let vForETA = max(1.5, vObs)
                let etaMin = Int((v.dist / vForETA / 60).rounded(.toNearestOrEven))
                return (found, max(0, etaMin))
            }
            return (nil, nil)
        }

        let dir = track.dirUnit

        struct Cand { let s: BusStop; let proj: Double; let lateral: Double; let dist: Double; let score: Double }
        let ranked: [Cand] = nearby.map { c in
            if let d = dir {
                let proj = c.dx*d.x + c.dy*d.y
                let lat  = abs(-c.dy*d.x + c.dx*d.y)
                let score = proj - lateralBias*lat
                return Cand(s: c.s, proj: proj, lateral: lat, dist: c.dist, score: score)
            } else {
                return Cand(s: c.s, proj: 0, lateral: c.dist, dist: c.dist, score: -c.dist)
            }
        }
        .sorted { $0.score == $1.score ? $0.dist < $1.dist : $0.score > $1.score }

        let ahead = (dir != nil) ? ranked.filter { $0.proj >= aheadProjMin } : ranked

        let lastId = lastPredictedStopId[busId]
        var chosen: Cand? = ahead.first
        if let lastId,
           let cur = ahead.first(where: { $0.s.id == lastId }) {
            let passed = cur.proj <= passBehindProj
            let keepByNear = cur.dist <= keepSameIfNearMeters
            let best = ahead.first
            let betterByMargin = (best != nil) && ((best!.score - cur.score) >= switchMarginMeters)

            if !passed && (keepByNear || !betterByMargin) {
                chosen = cur
            } else {
                chosen = best
            }
        }

        if chosen == nil, let name = fallbackByName {
            if let found = ranked.first(where: { name.contains($0.s.name) || $0.s.name.contains(name) }) {
                chosen = found
            }
        }

        guard let pick = chosen else { return (nil, nil) }

        let vObs = max(0.1, track.speedMps)
        let vForETA = max(1.5, vObs)
        let forwardMeters = max(0, pick.proj > 0 ? pick.proj : pick.dist)
        var etaSec = Int(forwardMeters / vForETA)
        if vObs < 1.2 && pick.dist < 25 { etaSec = 0 }
        let etaMin = max(0, Int((Double(etaSec)/60.0).rounded(.toNearestOrEven)))

        lastPredictedStopId[busId] = pick.s.id
        return (pick.s, etaMin)
    }




    // ⬇️ 이 메서드를 교체
    // ⬇️ 이 메서드를 교체
    // MapVM
    // ⬇️ 교체
    func onRegionCommitted(_ region: MKCoordinateRegion) {
        DBG.vm.log("🪝 regionCommitted begin")
        regionTask?.cancel()
        regionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)   // 0.65s 로 넉넉하게
            guard let self else { return }
            if self.reloadInFlight {                          // 실행 중이면 스킵
                DBG.vm.log("🪝 regionCommitted → SKIP (in-flight)")
                return
            }
            if self.shouldReload(for: region) {
                DBG.vm.log("🪝 regionCommitted → RELOAD")
                self.lastRegion = region
                self.lastReloadAt = Date()
                self.reloadTask?.cancel()
                self.reloadTask = Task { [weak self] in
                    guard let self else { return }
                    self.reloadInFlight = true
                    defer { self.reloadInFlight = false }
                    await self.reload(center: region.center)
                }
            } else {
                DBG.vm.log("🪝 regionCommitted → SKIP")
            }
        }
    }


    // MapVM 안에 추가
    private func nearestStops(from center: CLLocationCoordinate2D,
                              limit: Int = 4,
                              within meters: CLLocationDistance = 500) -> [BusStop] {
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return stops
            .map { stop -> (BusStop, CLLocationDistance) in
                let d = here.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
                return (stop, d)
            }
            .filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    // MapVM 안, private helpers 섹션
    /// RouteStops를 numericId 우선, 실패하면 rawId(DJB…)로 재시도해서 얻는다.
    private func fetchStopsForRoute(rawRouteId: String, routeNo: String?) async -> (stops: [BusStop], usedId: String?) {
        // 1순위: routeNo에서 저장해 둔 숫자ID
        if let no = routeNo, let num = numericRouteIdByRouteNo[no] {
            do {
                let s = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: num)
                if !s.isEmpty { return (s, num) }
            } catch { /* 무음 */ }
        }
        // 2순위: raw → 숫자 추출
        if let num2 = numericRouteId(from: rawRouteId) {
            do {
                let s = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: num2)
                if !s.isEmpty { return (s, num2) }
            } catch { /* 무음 */ }
        }
        // 3순위: raw 자체로 시도 (일부 엔드포인트가 허용할 수 있음)
        do {
            let s = try await api.fetchStopsByRoute(cityCode: CITY_CODE, routeId: rawRouteId)
            if !s.isEmpty { return (s, rawRouteId) }
        } catch { /* 무음 */ }

        return ([], nil)
    }
    // MapVM
    private func ensureRouteMetaOnce(rawRouteId: String, routeNo: String?) async -> Bool {
        // 캐시 히트
        if let m = routeMetaById[rawRouteId], m.shape.count >= 2, m.shape.count == m.cumul.count { return true }
        if let no = routeNo, let num = numericRouteIdByRouteNo[no],
           let m2 = routeMetaById[num], m2.shape.count >= 2, m2.shape.count == m2.cumul.count {
            routeMetaById[rawRouteId] = m2
            return true
        }

        // 1) 정류장 확보
        let (stops, usedId) = await fetchStopsForRoute(rawRouteId: rawRouteId, routeNo: routeNo)
        let idForCache = usedId ?? (numericRouteId(from: rawRouteId) ?? rawRouteId)

        // 2) 경로(path) 요청 (numeric 우선)
        var shape: [CLLocationCoordinate2D] = []
        if let num = numericRouteId(from: rawRouteId) {
            shape = (try? await api.fetchRoutePath(cityCode: CITY_CODE, routeId: num)) ?? []
        }
        if shape.count < 2 {
            shape = (try? await api.fetchRoutePath(cityCode: CITY_CODE, routeId: rawRouteId)) ?? []
        }

        // 3) 폴백: path가 없고 stops가 있으면 정류장 연결로 대체
        if shape.count < 2, stops.count >= 2 {
            shape = stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }

        let cumul = buildCumul(shape)
        guard shape.count >= 2, cumul.count == shape.count else { return false }

        let stopS = stopsProjectedS(stops, shape: shape, cumul: cumul)
        let meta = RouteMeta(
            shape: shape, cumul: cumul,
            stopIds: stops.map { $0.id },
            stopCoords: stops.map { .init(latitude: $0.lat, longitude: $0.lon) },
            stopS: stopS
        )

        // 양쪽 키에 캐시
        routeMetaById[idForCache] = meta
        routeMetaById[rawRouteId] = meta
        if let no = routeNo, let num = numericRouteId(from: rawRouteId) {
            numericRouteIdByRouteNo[no] = num
        }
        clearCooldown(rawRouteId); clearCooldown(idForCache)
        return true
    }

    // MapVM
    private func integrateKnownStops(_ arr: [BusStop]) {
        for s in arr { knownStopsIndex[s.id] = s }
    }
    // MapVM 안
    // MapVM
    @MainActor
    func reload(center: CLLocationCoordinate2D) async {
        // ── epoch/상태 준비 ─────────────────────────────────────────────────────────
        epochCounter &+= 1
        let epoch = epochCounter
        self.lastStopRefreshCenter = center

        // 가벼운 로거 (DBG 시그니처 문제 피하려고 print 사용)
        func V(_ msg: String) { print(msg) }
        func E(_ msg: String) { print("❌ " + msg) }

        V("🔄 reload(epoch=\(epoch)) center=(\(center.latitude), \(center.longitude))")

        // ── 1) 주변 정류장 가져오기 (취소는 정상 취소로 무시) ───────────────────────────
        do {
            let t0 = Date()
            let fetched = try await api.fetchStops(lat: center.latitude, lon: center.longitude)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            V("🚌 Stops fetched=\(fetched.count) in \(ms)ms")

            applyIfCurrent(epoch: epoch) {
                self.stops = fetched
                self.integrateKnownStops(fetched)
            }
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                V("ℹ️ fetchStops cancelled (ignore)")
                return // 취소면 조용히 리턴 (화면 상태 유지)
            } else {
                E("fetchStops error: \(ns)")
                return // 네트워크 에러여도 기존 화면 유지
            }
        }

        // ── 1.5) 도착정보는 ‘가까운 N개 정류장’ 기준으로만 호출 ─────────────────────────
        let candidates = nearestStops(from: center, limit: 4, within: 500)
        guard !candidates.isEmpty else {
            V("ℹ️ no nearby stops within 500m → clearing lists")
            applyIfCurrent(epoch: epoch) {
                self.latestTopArrivals = []
                self.buses = []
            }
            return
        }

        // ── 2) 도착정보 수집 & 상위 노선 선정 ────────────────────────────────────────────
        do {
            var allArrivals: [ArrivalInfo] = []
            let t0 = Date()

            try await withThrowingTaskGroup(of: [ArrivalInfo].self) { group in
                for s in candidates {
                    group.addTask { try await self.api.fetchArrivalsDetailed(cityCode: CITY_CODE, nodeId: s.id) }
                }
                while let arr = try await group.next() {
                    allArrivals.append(contentsOf: arr)
                }
            }

            V("🧾 arrivals total=\(allArrivals.count)")
            let top = computeTopArrivals(
                allArrivals: allArrivals,
                followedRouteNo: (followBusId.flatMap { routeNoById[$0] })
            )
            V("🏅 top routes=\(top.count)  sample=\(top.prefix(3).map{ "\($0.routeNo)=\($0.etaMinutes)m" })  took=\(Int(Date().timeIntervalSince(t0)*1000))ms")

            applyIfCurrent(epoch: epoch) { self.latestTopArrivals = top }

            // 상위 노선이 없으면 여기서 종료(버스도 비움)
            guard !top.isEmpty else {
                applyIfCurrent(epoch: epoch) { self.buses = [] }
                return
            }

            // ── 3) 버스 위치 동시 호출 → 경로 스냅/필터링 병합 ─────────────────────────
            let snap = makeRouteSnapshot()
            let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
            var mergedById: [String: BusLive] = [:]

            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let raw = try await group.next() {
                    // ETA 주입 후, 내부 스냅/필터 파이프라인 태움
                    let enriched = raw.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched, snap: snap)

                    // routeNo 캐시 & 병합
                    for b in filtered {
                        self.routeNoById[b.id] = b.routeNo
                        mergedById[b.id] = b
                    }

                    // 팔로우 유령 보정(실시간 끊김 대비)
                    self.ensureFollowGhost(&mergedById)

                    applyIfCurrent(epoch: epoch) {
                        self.buses = Array(mergedById.values)
                    }
                }
            }

            // 자동 새로고침 루프 킵
            startAutoRefresh()

        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                V("ℹ️ arrivals/busloc cancelled (keep previous)")
                return
            }
            E("arrivals/busloc error: \(ns)")
            applyIfCurrent(epoch: epoch) {
                self.buses = []
                self.latestTopArrivals = []
            }
        }
        
        print("🟢 stops fetched count=\(stops.count)")
        for s in stops {
            print("🟢 stop=\(s.id) \(s.name) (\(s.lat), \(s.lon))")
        }

        
    }





  
    private func startAutoRefresh() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BUS_REFRESH_SEC * 1_000_000_000)
                await self.refreshBusesOnly()
            }
        }
    }

    // MapVM
    private func refreshBusesOnly() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        epochCounter &+= 1
        let epoch = epochCounter

        // 기존 상위 노선
        var top = computeTopArrivals(allArrivals: latestTopArrivals,
                                     followedRouteNo: (followBusId.flatMap { routeNoById[$0] }))

        // ★ 팔로우 중이면 해당 노선을 항상 포함 (도착정보 상위에서 빠져도 계속 조회)
        if let fid = followBusId,
           let rno = routeNoById[fid],
           let rid = resolveRouteId(for: rno),
           top.first(where: { $0.routeId == rid }) == nil {

            top.append(ArrivalInfo(routeId: rid, routeNo: rno, etaMinutes: 5)) // ETA 더미
        }

        guard !top.isEmpty else { return }

        let snap = makeRouteSnapshot()
        let etaByRoute = Dictionary(uniqueKeysWithValues: top.map { ($0.routeNo, $0.etaMinutes) })
        var mergedById: [String: BusLive] = Dictionary(uniqueKeysWithValues: self.buses.map { ($0.id, $0) })

        do {
            try await withThrowingTaskGroup(of: [BusLive].self) { group in
                for a in top {
                    group.addTask { try await self.api.fetchBusLocations(cityCode: CITY_CODE, routeId: a.routeId) }
                }
                while let arr = try await group.next() {
                    let enriched = arr.map { var m = $0; m.etaMinutes = etaByRoute[m.routeNo]; return m }
                    let filtered = self.mergeAndFilter(enriched, snap: snap)
                    for b in filtered { self.routeNoById[b.id] = b.routeNo; mergedById[b.id] = b }
                    self.ensureFollowGhost(&mergedById)
                    applyIfCurrent(epoch: epoch) {
                        self.buses = Array(mergedById.values)
                    }
                }
            }
        } catch { /* 무음 */ }

        // ★ 팔로우 대상 재획득(사라졌다면 같은 노선에서 가장 가까운 버스로 스위칭)
        if let fid = followBusId,
           self.buses.first(where: { $0.id == fid }) == nil,
           let rno = routeNoById[fid] {

            let cand = self.buses
                .filter { $0.routeNo == rno }
                .min { lhs, rhs in
                    let a = CLLocation(latitude: lhs.lat, longitude: lhs.lon)
                    let b = CLLocation(latitude: rhs.lat, longitude: rhs.lon)
                    let last = tracks[fid]?.lastLoc
                    guard let last else { return false }
                    let la = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    return la.distance(from: a) < la.distance(from: b)
                }

            if let c = cand { followBusId = c.id } // 자연스러운 재연결
        }
    }

    
    
    

    
    private var lastPassedStopIndex: [String: Int] = [:]
    /// 단순 방향 기반 정류장 통과 판정
    private func hasPassedStop(bus: CLLocationCoordinate2D,
                               stop: CLLocationCoordinate2D,
                               direction: CGPoint) -> Bool {
        // 주 진행방향이 동서(E-W)인지 남북(N-S)인지 결정
        if abs(direction.x) > abs(direction.y) {
            // 동서 이동
            if direction.x > 0 {
                // 동쪽(경도 증가) → 정류소 경도보다 버스 경도가 크면 통과
                return bus.longitude > stop.longitude
            } else {
                // 서쪽(경도 감소) → 정류소 경도보다 버스 경도가 작으면 통과
                return bus.longitude < stop.longitude
            }
        } else {
            // 남북 이동
            if direction.y > 0 {
                // 북쪽(위도 증가)
                return bus.latitude > stop.latitude
            } else {
                // 남쪽(위도 감소)
                return bus.latitude < stop.latitude
            }
        }
    }
    // 버스별 "다음 정류장 index"를 기억(단조 증가, 절대 후퇴 없음)
    // 버스별 현재 노선(routeId) 기억(초기화용)
    private var busRouteIdByBusId: [String: String] = [:]
    /// 노선 위 진행거리 s 와 정류장 누적거리 배열 stopS 를 비교해
    /// '다음 정류장'의 index 를 단조 증가로 갱신한다.
    private func monotonicNextStopIndex(
        busId: String,
        routeId: String,
        progressS: Double,
        lateralMeters: Double,
        stopsCount: Int,
        stopS: [Double]
    ) -> Int {
        // 경로에서 너무 벗어나 있으면(병렬 도로 등) index 고정
        let lateralMax: Double = 120.0
        if lateralMeters > lateralMax, let keep = lastNextStopIndexByBusId[busId] {
            return keep
        }

        // 초기화: s와 가장 가까운 정류장을 기준으로 다음 정류장 가정
        let currentIdx: Int = {
            if let cached = lastNextStopIndexByBusId[busId] { return cached }
            // s와 stopS 차이가 최소인 지점
            let j = stopS.enumerated().min(by: { abs($0.element - progressS) < abs($1.element - progressS) })?.offset ?? 0
            // 이미 j를 충분히 지난 상태면 j+1부터 시작
            let gate: Double = 20.0 // 20m 지나야 '지남' 인정
            return min(j + (progressS > stopS[j] + gate ? 1 : 0), stopsCount - 1)
        }()

        var idx = currentIdx
        let gate: Double = 20.0 // s가 stopS[idx]+gate 를 넘으면 다음으로 진급
        while idx < stopsCount - 1, progressS >= stopS[idx] + gate {
            idx += 1
        }

        lastNextStopIndexByBusId[busId] = idx
        busRouteIdByBusId[busId] = routeId
        return idx
    }

    // MapVM
    private func mergeAndFilter(_ incoming: [BusLive], snap: RouteSnapshot) -> [BusLive] {
        var out: [BusLive] = []

        // 튜닝(기존 값 유지)
        let LATERAL_MAX_M: Double = 60
        let PASS_GATE_M: Double   = 18
        let SPEED_FLOOR_MPS: Double = 1.5
        let NEAR_STOP_M: Double   = 25
        let MAX_STEP_M: Double    = 300
        let EMA_ALPHA: Double     = 0.35
        let MAX_PLAUSIBLE_MPS: Double = 40.0
        let FOLLOW_STEP_ALLOW_METERS: CLLocationDistance = 1200

        for var b in incoming {
            let now = Date()
            let rawC = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)

            // ★ 합성 ID 만들기 (routeId가 꼭 필요)
            guard let rid = resolveRouteId(for: b.routeNo) else { continue }
            let cid = compoundBusId(routeId: rid, rawVehId: b.id)  // ← "routeId#vehicleno"

            // ★ 새 BusLive로 재구성(Struct라 id 변경 불가)
            var bus = BusLive(
                id: cid,
                routeNo: b.routeNo,
                lat: b.lat,
                lon: b.lon,
                etaMinutes: b.etaMinutes,
                nextStopName: b.nextStopName
            )

            let isFollowed = (followBusId == bus.id)

            // 1) 트랙 준비
            let nowC = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
            if tracks[bus.id] == nil {
                tracks[bus.id] = BusTrack(prevLoc: nil, prevAt: nil, lastLoc: nowC, lastAt: now)
                out.append(bus)
                continue
            }
            var tr = tracks[bus.id]!

            // 2) 점프/EMA
            let step = CLLocation(latitude: tr.lastLoc.latitude, longitude: tr.lastLoc.longitude)
                .distance(from: CLLocation(latitude: nowC.latitude, longitude: nowC.longitude))
            let dt = max(0.01, now.timeIntervalSince(tr.lastAt))
            let instMps = step / dt

            var acceptAsJump = false
            if step > MAX_STEP_M {
                if isFollowed && step <= FOLLOW_STEP_ALLOW_METERS { acceptAsJump = true }
                else if instMps <= MAX_PLAUSIBLE_MPS { acceptAsJump = true }
            }
            if step > MAX_STEP_M && !acceptAsJump {
                out.append(bus); continue
            }

            let alpha = acceptAsJump ? 0.9 : EMA_ALPHA
            let smooth = CLLocationCoordinate2D(
                latitude:  tr.lastLoc.latitude  * (1 - alpha) + nowC.latitude  * alpha,
                longitude: tr.lastLoc.longitude * (1 - alpha) + nowC.longitude * alpha
            )
            tr.prevLoc = tr.lastLoc
            tr.prevAt  = tr.lastAt
            tr.lastLoc = smooth
            tr.lastAt  = now
            tr.updateKinematics()
            tracks[bus.id] = tr

            // 3) 메타/사영
            guard let meta = snap.metaById[rid],
                  let rStops = snap.stopsByRouteId[rid],
                  let prj = projectOnRoute(smooth, shape: meta.shape, cumul: meta.cumul)
            else {
                // 메타 없음 → coast
                let pred = tr.coastPredict(at: now.addingTimeInterval(0.6),
                                           decay: COAST_DECAY_PER_SEC, minSpeed: COAST_MIN_SPEED)
                bus.lat = pred.latitude
                bus.lon = pred.longitude
                if let prev = lastETAMinByBusId[bus.id] { bus.etaMinutes = prev }

                if followBusId == bus.id {
                    let c = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                    trail.appendIfNeeded(c); trailVersion &+= 1
                }
                out.append(bus)
                continue
            }

            if prj.lateral > LATERAL_MAX_M {
                if let prev = lastETAMinByBusId[bus.id] { bus.etaMinutes = prev }
                if followBusId == bus.id {
                    let c = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                    trail.appendIfNeeded(c); trailVersion &+= 1
                }
                out.append(bus)
                continue
            }

            // 경로 위로 클램프
            bus.lat = prj.snapped.latitude
            bus.lon = prj.snapped.longitude

            // 4) 다음 정류장 인덱스/ETA
            let stopS = meta.stopS
            let count = min(stopS.count, rStops.count)
            guard count > 0 else { out.append(bus); continue }

            var passed = lastPassedStopIndex[bus.id] ?? -1
            while passed + 1 < count && (prj.s - stopS[passed + 1]) >= PASS_GATE_M {
                passed += 1
            }
            if let last = lastPassedStopIndex[bus.id] { passed = max(passed, last) }
            lastPassedStopIndex[bus.id] = passed

            let nextIdx = min(passed + 1, count - 1)
            let nextStop = rStops[nextIdx]
            bus.nextStopName = nextStop.name

            let remaining = max(0, stopS[nextIdx] - prj.s)
            let vObs = max(0.1, tr.speedMps)
            let vForETA = max(SPEED_FLOOR_MPS, vObs)
            var sec = Int(remaining / vForETA)
            if vObs < 1.2 && remaining < NEAR_STOP_M { sec = 0 }
            let rawETA = max(0, Int((Double(sec)/60.0).rounded(.toNearestOrEven)))
            if let e = smoothETA(rawETA: rawETA, busId: bus.id, distToNextStop: remaining) {
                bus.etaMinutes = e
                lastETAMinByBusId[bus.id] = e
            } else if let prev = lastETAMinByBusId[bus.id] {
                bus.etaMinutes = prev
            }

            // 스냅
            maybeSnapToStop(&bus)

            // 팔로우 중: 트레일/하이라이트/미래경로
            if followBusId == bus.id {
                let c = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                trail.appendIfNeeded(c); trailVersion &+= 1
                highlightedStopId = nextStop.id
                setFutureRouteByStops(meta: meta, from: prj, nextIdx: nextIdx, maxAheadStops: 7, includeTerminal: false)
            }

            out.append(bus)
        }

        return out
    }

    
    // MapVM 내부 어디든 private helper로 추가
    private func compoundBusId(routeId: String, rawVehId: String) -> String {
        return "\(routeId)#\(rawVehId)"
    }

    
    

    // MapVM 내부 (private helpers 섹션에)
    private func buildFutureRouteStopByStop(
        meta: RouteMeta,
        prj: (snapped: CLLocationCoordinate2D, s: Double, seg: Int, lateral: Double),
        nextStartIdx: Int
    ) -> [CLLocationCoordinate2D] {
        guard meta.shape.count >= 2, meta.shape.count == meta.cumul.count else { return [] }
        guard nextStartIdx < meta.stopS.count else { return [prj.snapped] }

        var coords: [CLLocationCoordinate2D] = [prj.snapped]

        var curSeg = prj.seg
        var curS   = prj.s

        // 다음 정류장부터 종점까지 반복
        for j in nextStartIdx ..< meta.stopS.count {
            let targetS = meta.stopS[j]

            // 1) 현재 s -> targetS 구간의 shape 포인트를 순서대로 추가
            var i = max(curSeg + 1, 0)
            while i < meta.cumul.count, meta.cumul[i] < targetS {
                coords.append(meta.shape[i])
                i += 1
            }

            // 2) 정류장 좌표를 정확히 추가(꺾임 보장)
            coords.append(meta.stopCoords[j])

            // 상태 갱신
            curSeg = min(max(i - 1, 0), meta.shape.count - 2)
            curS   = targetS
        }

        // 너무 가까운 중복점 제거(선택)
        if coords.count >= 2 {
            var cleaned: [CLLocationCoordinate2D] = [coords[0]]
            for c in coords.dropFirst() {
                let d = CLLocation(latitude: cleaned.last!.latitude, longitude: cleaned.last!.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                if d >= 2 { cleaned.append(c) }
            }
            return cleaned
        } else {
            return coords
        }
    }


    // MapVM 안 (private helpers 섹션)

    // 국토부 routeId는 숫자형만 유효
    // MapVM 안
    private func isMotieRouteId(_ id: String) -> Bool {
        // 순수 숫자이거나, "DJB"로 시작하는 로컬 ID는 모두 허용
        return Int(id) != nil || id.hasPrefix("DJB")
    }
    // MapVM 안에 추가
    func redrawFutureRouteFromUpcoming(busId: String, maxCount: Int = 7) {
        // 0) 라이브/루트 메타 확보
        guard let live = buses.first(where: { $0.id == busId }) else { return }
        let here = CLLocationCoordinate2D(latitude: live.lat, longitude: live.lon)

        let routeNo = routeNoById[busId] ?? live.routeNo
        guard let rid = resolveRouteId(for: routeNo),
              let meta = routeMetaById[rid],
              meta.shape.count >= 2,
              meta.shape.count == meta.cumul.count,
              let prj = projectOnRoute(here, shape: meta.shape, cumul: meta.cumul) else {
            // 메타 없으면 임시 직선 폴백
            setTemporaryFutureRouteFromBus(busId: busId, coordinate: here, meters: 1200)
            return
        }

        // 1) 현재 패널에서 쓰는 목록과 동일하게 다음 정류장 추출 (중복 제거 포함)
        let raw = upcomingStops(for: busId, maxCount: maxCount)
        var seen = Set<String>()
        let nexts = raw.filter { seen.insert($0.id).inserted }

        // 2) 현재 스냅점 + 정류장 좌표(최대 N개)만 직선으로 잇는 꺾은선 구성
        var coords: [CLLocationCoordinate2D] = [prj.snapped]
        for it in nexts {
            if let j = meta.stopIds.firstIndex(of: it.id) {
                coords.append(meta.stopCoords[j])
            }
        }

        // 3) 적용
        if coords.count >= 2 {
            futureRouteCoords = coords
        } else {
            futureRouteCoords.removeAll()
        }
        futureRouteVersion &+= 1
    }

    // ✅ 공격적 필터 → 안전한 폴백 포함
    /// 도착정보(allArrivals)를 routeId별 최소 ETA로 모아서 상위 목록을 만든다.
    /// - DJB/숫자 routeId 모두 유지(버스 조회용)
    /// - 동시에 `numericRouteIdByRouteNo`(메타 전용 숫자 id)와 `routeNoByRouteId`(역캐시)도 채움
    /// 도착정보를 routeId별 최소 ETA로 모으고, 캐시를 채운 뒤 정렬해 돌려준다.
    private func computeTopArrivals(
        allArrivals: [ArrivalInfo],
        followedRouteNo: String?
    ) -> [ArrivalInfo] {

        print("ℹ️ arrivals total=\(allArrivals.count)  uniques(routeId)=\(Set(allArrivals.map{$0.routeId}).count)")

        var bestByRoute: [String: ArrivalInfo] = [:]
        var numericMapped = 0

        for a in allArrivals {
            // routeNo ↔ routeId 기본 매핑
            routeIdByRouteNo[a.routeNo] = a.routeId
            lastKnownRouteIdByRouteNo[a.routeNo] = a.routeId
            routeNoByRouteId[a.routeId] = a.routeNo

            // 지역형 routeId에서 숫자ID를 추출해서 캐시에 보관
            if let num = numericRouteId(from: a.routeId) {
                numericRouteIdByRouteNo[a.routeNo] = num
                numericMapped += 1
            }

            // 같은 노선(routeId) 내 최소 ETA 유지
            if let cur = bestByRoute[a.routeId] {
                if a.etaMinutes < cur.etaMinutes { bestByRoute[a.routeId] = a }
            } else {
                bestByRoute[a.routeId] = a
            }
        }

        var top = Array(bestByRoute.values)
        print("ℹ️ after per-route minETA: \(top.count) routes, numeric-mapped routeNo=\(numericMapped)")

        if let fr = followedRouteNo {
            top.sort { lhs, rhs in
                if lhs.routeNo == fr { return true }
                if rhs.routeNo == fr { return false }
                return lhs.etaMinutes < rhs.etaMinutes
            }
            print("ℹ️ sorted with followedRouteNo=\(fr)")
        } else {
            top.sort { $0.etaMinutes < $1.etaMinutes }
        }

        print("ℹ️ top sample: \(top.prefix(3).map{ "\($0.routeNo)=\($0.routeId) (\($0.etaMinutes)m)" })")
        return top
    }







    // MapVM 안 기존 메서드를 이걸로 교체
    private func maybeSnapToStop(_ b: inout BusLive) {
        guard let rid = resolveRouteId(for: b.routeNo),
              let meta = routeMetaById[rid],
              let idxPassed = lastPassedStopIndex[b.id] else {
            // 메타 없거나 아직 인덱스 못 잡았으면 스킵
            if let until = dwellUntil[b.id], until < Date() { dwellUntil.removeValue(forKey: b.id) }
            return
        }

        let nextIdx = min(idxPassed + 1, meta.stopS.count - 1)
        let targetLat = meta.stopCoords[nextIdx].latitude
        let targetLon = meta.stopCoords[nextIdx].longitude

        // 현 위치와 타깃 정류장 거리
        let d = CLLocation(latitude: b.lat, longitude: b.lon)
            .distance(from: CLLocation(latitude: targetLat, longitude: targetLon))

        if d < snapRadius {
            // 드웰 시작/연장
            let until = dwellUntil[b.id] ?? .distantPast
            if until < Date() { dwellUntil[b.id] = Date().addingTimeInterval(dwellSec) }

            // 스냅 + ETA 0
            b.lat = targetLat
            b.lon = targetLon
            b.nextStopName = stops.first(where: { $0.id == meta.stopIds[nextIdx] })?.name ?? b.nextStopName
            b.etaMinutes = 0
        } else {
            // 반경 벗어나고 드웰 만료면 해제
            if let until = dwellUntil[b.id], until < Date() { dwellUntil.removeValue(forKey: b.id) }
        }
    }


    
    
    
}

extension BusAPI {
    /// 서울시: 노선번호로 busRouteId 목록 조회
    func fetchRouteIdsByRouteNo(cityCode: Int, routeNo: String) async throws -> [String] {
        // 서울시: /busRouteInfo/getBusRouteList?strSrch=...
        let url = makeSeoulURL(
            path: "/busRouteInfo/getBusRouteList",
            params: [
                .init(name: "serviceKey", value: serviceKeyEncoded), // raw 그대로
                .init(name: "strSrch", value: routeNo),
                .init(name: "resultType", value: "json")
            ])

        struct Root: Decodable {
            struct ServiceResult: Decodable {
                struct Body: Decodable { let itemList: OneOrMany<Item>? }
                let msgBody: Body?
            }
            struct Item: Decodable {
                let busRouteId: String?
                let rtNm: String?
            }
            let ServiceResult: ServiceResult?
        }

        let (data, http) = try await send("RouteList(Seoul)", url: url)
        if let s = String(data: data, encoding: .utf8) {
            print("🔎 RouteList raw(\(http.statusCode)): \(s.prefix(240))")
        }

        let r = try JSONDecoder().decode(Root.self, from: data)
        let items = r.ServiceResult?.msgBody?.itemList?.array ?? []
        let ids = items.compactMap { $0.busRouteId }
        print("🔎 getBusRouteList(\(routeNo)) → \(ids.count) ids, sample=\(ids.prefix(5))")
        return ids
    }
}




enum BusProvider { case motie /*국토부*/, daejeon }
private let provider: BusProvider = .motie   // ← 임시로 대전 active

// MARK: - Map helpers
private extension MKMapView {
    var isRegionChangeFromUserInteraction: Bool {
        guard let grs = subviews.first?.gestureRecognizers else { return false }
        return grs.contains { $0.state == .began || $0.state == .ended || $0.state == .changed }
    }
}

// MARK: - Map View
struct ClusteredMapView: UIViewRepresentable {
    @ObservedObject var vm: MapVM
    @Binding var recenterRequest: Bool

    func makeUIView(context: Context) -> MKMapView {
           let map = MKMapView(frame: .zero)
           map.delegate = context.coordinator
           map.showsUserLocation = true

        // ✅ 무조건 서울시청에서 시작
        map.region = .init(center: SEOUL_CITY_HALL,
                           span: .init(latitudeDelta: 0.045, longitudeDelta: 0.045))

           map.pointOfInterestFilter = .includingAll
           map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
           map.register(BusMarkerView.self, forAnnotationViewWithReuseIdentifier: "bus")
           map.register(ClusterView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
           return map
       }


    func updateUIView(_ uiView: MKMapView, context: Context) {
        // 내 위치 버튼 처리
        if recenterRequest {
            defer { DispatchQueue.main.async { self.recenterRequest = false } }
            let status = CLLocationManager.authorizationStatus()
            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                print("📍 recenter skipped (auth=\(status))"); return
            }
            if let loc = uiView.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(loc) {
                context.coordinator.centerOn(loc, mapView: uiView, animated: true)
            } else {
                print("📍 user location not ready – skip")
            }
        }

        // 1) 스냅샷
        let currentStops = uiView.annotations.compactMap { $0 as? BusStopAnnotation }
        let currentBuses = uiView.annotations.compactMap { $0 as? BusAnnotation }
        let currentStopIds = Set(currentStops.map { $0.stop.id })

        // 2) 원하는 상태
        var desiredStops = vm.stops
        // ✅ 하이라이트 정류장을 강제로 포함(화면 반경 밖이어도 색 바뀌도록)
        if let hs = vm.highlightedBusStop(),
           !desiredStops.contains(where: { $0.id == hs.id }) {
            desiredStops.append(hs)
        }
        let desiredBuses = vm.buses
        let desiredStopIds = Set(desiredStops.map { $0.id })

        // add/remove
        let stopsToAdd    = desiredStops.filter { !currentStopIds.contains($0.id) }.map { BusStopAnnotation($0) }
        let stopsToRemove = currentStops.filter { !desiredStopIds.contains($0.stop.id) }

        var busAnnoById = Dictionary(uniqueKeysWithValues: currentBuses
            .filter { !$0.id.isEmpty }
            .map { ($0.id, $0) })
        var busesToAdd: [BusAnnotation] = []
        var busesToRemove: [BusAnnotation] = []
        var busUpdates: [(BusAnnotation, BusLive)] = []

        for b in desiredBuses {
            if let anno = busAnnoById.removeValue(forKey: b.id) {
                busUpdates.append((anno, b))
            } else {
                busesToAdd.append(BusAnnotation(bus: b))
            }
        }
        for leftover in busAnnoById.values {
            if let sel = vm.followBusId, sel == leftover.id { continue } // ✅ 팔로우 삭제 금지
            let stillDesired = desiredBuses.contains { $0.id == leftover.id }
            if stillDesired { continue }
            busesToRemove.append(leftover)
        }

        // 3) 일괄 적용
        context.coordinator.applyAnnotationDiff(
            on: uiView,
            stopsToAdd: stopsToAdd,
            stopsToRemove: stopsToRemove,
            busesToAdd: busesToAdd,
            busesToRemove: busesToRemove,
            busUpdates: busUpdates
        )

        // 4) 팔로우 중이면 재센터+색상 최신화
        if let followId = vm.followBusId, vm.stickToFollowedBus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let anno = uiView.annotations.first(where: { ($0 as? BusAnnotation)?.id == followId }) as? BusAnnotation {
                    context.coordinator.follow(anno, on: uiView)
                    if let v = uiView.view(for: anno) as? BusMarkerView {
                        v.configureTint(isFollowed: true)
                        v.updateAlwaysOnBubble()
                    }
                }
            }
        }

        // 5) 배치 후 팔로우 색상/라벨 일괄 재도색(안전망)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            context.coordinator.updateFollowTints(uiView)
        }
        // updateUIView 내 배치 후
        context.coordinator.updateTrailOverlay(uiView)       // 주황(지나온) 갱신
        context.coordinator.updateFutureRouteOverlay(uiView) // 빨강(미래) 갱신
        // 정류장 색상 안전망
        context.coordinator.recolorStops(uiView)



    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, MKMapViewDelegate {
        let parent: ClusteredMapView
        private let deb = Debouncer()
        private var isAutoRecentering = false
        private var isApplyingDiff = false
        private var isTweakingFollowAppearance = false    // 재진입/중복 호출 가드


        init(_ p: ClusteredMapView) { parent = p }
        // ClusteredMapView.Coord 내부에 추가
        // ClusteredMapView.Coord 내부에 넣기 (교체/추가)
        // ClusteredMapView.Coord
        // ClusteredMapView.Coord 안에 추가
        // ClusteredMapView.Coord
        func updateFutureRouteOverlay(_ mapView: MKMapView) {
            // 기존 futureRoute 제거 (title 옵셔널 안전비교)
            let olds = mapView.overlays.compactMap { $0 as? MKPolyline }.filter { ($0.title ?? "") == "futureRoute" }
            if !olds.isEmpty { mapView.removeOverlays(olds) }

            let coords = parent.vm.futureRouteCoords
            guard coords.count >= 2 else { return }

            let line = MKPolyline(coordinates: coords, count: coords.count)
            line.title = "futureRoute"
            mapView.addOverlay(line)
        }





        // 추적 색상 일괄 반영
        func updateFollowTints(_ mapView: MKMapView) {
            // MapKit이 내부에서 enumerate 중일 수 있으므로, diff/애니메이션 중이면 잠깐 뒤로 미룸
            if isApplyingDiff || isTweakingFollowAppearance {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.updateFollowTints(mapView)
                }
                return
            }

            isTweakingFollowAppearance = true

            // ✅ 스냅샷을 떠서 열거 중 뮤테이션 방지
            let annoSnapshot: [MKAnnotation] = Array(mapView.annotations)

            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                let followed = parent.vm.followBusId

                for anno in annoSnapshot {
                    guard let a = anno as? BusAnnotation,
                          let v = mapView.view(for: a) as? BusMarkerView else { continue }

                    let isFollowed = (a.id == followed)

                    // 팔로우 중 버스는 절대 클러스터에 합쳐지지 않도록 "고유" ID 사용(= nil 금지)
                    let newClusterId = isFollowed ? "bus-\(a.id)" : "bus"
                    if v.clusteringIdentifier != newClusterId {
                        v.clusteringIdentifier = newClusterId
                    }

                    v.configureTint(isFollowed: isFollowed)
                    v.displayPriority = .required
                    v.layer.zPosition = 10
                }

                CATransaction.commit()
            }

            isTweakingFollowAppearance = false
        }



        // ClusteredMapView.Coord 안의 기존 메서드 교체
        // ClusteredMapView.Coord
        func applyAnnotationDiff(
            on mapView: MKMapView,
            stopsToAdd: [MKAnnotation],
            stopsToRemove: [MKAnnotation],
            busesToAdd: [MKAnnotation],
            busesToRemove: [MKAnnotation],
            busUpdates: [(BusAnnotation, BusLive)]
        ) {
            if isApplyingDiff { return }
            isApplyingDiff = true

            // 1단계: add/remove 만 (동일 런루프)
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView else { return }

                let present = Set(mapView.annotations.map { ObjectIdentifier($0) })
                let updatingBusIds = Set(busUpdates.map { $0.0.id })
                let followedId = self.parent.vm.followBusId
                let selectedIds = Set(mapView.selectedAnnotations.compactMap { ($0 as? BusAnnotation)?.id })

                let safeStopsToRemove = stopsToRemove.filter { present.contains(ObjectIdentifier($0)) }
                let safeBusesToRemove: [MKAnnotation] = busesToRemove.compactMap { a in
                    guard present.contains(ObjectIdentifier(a)) else { return nil }
                    guard let b = a as? BusAnnotation else { return a }
                    if let fid = followedId, fid == b.id { return nil }
                    if selectedIds.contains(b.id) { return nil }
                    if updatingBusIds.contains(b.id) { return nil }
                    return b
                }

                UIView.performWithoutAnimation {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if !safeStopsToRemove.isEmpty || !safeBusesToRemove.isEmpty {
                        mapView.removeAnnotations(safeStopsToRemove + safeBusesToRemove)
                    }
                    if !stopsToAdd.isEmpty || !busesToAdd.isEmpty {
                        mapView.addAnnotations(stopsToAdd + busesToAdd)
                    }
                    CATransaction.commit()
                }

                // 2단계: 다음 런루프에서 뷰 접근/업데이트 (안전 시점)
                DispatchQueue.main.async { [weak self, weak mapView] in
                    guard let self, let mapView else { return }

                    if !busUpdates.isEmpty {
                        CATransaction.begin()
                        CATransaction.setAnimationDuration(0.9)
                        for (anno, live) in busUpdates {
                            anno.update(to: live) // 좌표/자막 갱신 (setSubtitle가 async-KVO)
                            if let mv = mapView.view(for: anno) as? BusMarkerView {
                                mv.updateAlwaysOnBubble()
                            }
                        }
                        CATransaction.commit()
                    }

                    // 배치 후 후처리(모두 이 시점에서만)
                    self.updateFollowTints(mapView)
                    self.recolorStops(mapView)
                    self.safeDeconflictAll(mapView) // ⬅️ 새 메서드 (아래 4번)

                    self.isApplyingDiff = false
                }
            }
            print("🟢 applyAnnotationDiff: adding=\(busesToAdd.count) removing=\(busesToRemove.count)")

        }
        
        // ClusteredMapView.Coord
        func safeDeconflictAll(_ mapView: MKMapView) {
            // CRASH FIX: 배치가 끝난 “다음” 런루프에서 일괄 처리
            DispatchQueue.main.async {
                let buses = mapView.annotations.compactMap { $0 as? BusAnnotation }
                let stops = mapView.annotations.compactMap { $0 as? BusStopAnnotation }

                for bus in buses {
                    guard let v = mapView.view(for: bus) else { continue }
                    let defaultOffset = CGPoint(x: 0, y: -10)

                    // 가장 가까운 정류장만 검사
                    guard let nearest = stops.min(by: { lhs, rhs in
                        let dl = CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude)
                            .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                        let dr = CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude)
                            .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                        return dl < dr
                    }) else {
                        (v as? MKAnnotationView)?.centerOffset = defaultOffset
                        continue
                    }

                    let dist = CLLocation(latitude: nearest.coordinate.latitude, longitude: nearest.coordinate.longitude)
                        .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))

                    let threshold: CLLocationDistance = 8.0
                    guard dist <= threshold else {
                        (v as? MKAnnotationView)?.centerOffset = defaultOffset
                        continue
                    }

                    let dx = bus.coordinate.longitude - nearest.coordinate.longitude
                    let dy = bus.coordinate.latitude  - nearest.coordinate.latitude
                    let mag = max(1e-9, sqrt(dx*dx + dy*dy))
                    let bump: CGFloat = 6.0
                    let px = CGFloat(dx / mag) * bump
                    let py = CGFloat(-dy / mag) * bump

                    (v as? MKAnnotationView)?.centerOffset = CGPoint(x: defaultOffset.x + px, y: defaultOffset.y + py)
                }
            }
        }


        


        func centerOn(_ center: CLLocationCoordinate2D, mapView: MKMapView, animated: Bool) {
            isAutoRecentering = true
            mapView.setCenter(center, animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.isAutoRecentering = false }
        }

        func follow(_ anno: BusAnnotation, on mapView: MKMapView) {
            guard CLLocationCoordinate2DIsValid(anno.coordinate) else { return }
            let center = mapView.centerCoordinate
            let a = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let b = CLLocation(latitude: anno.coordinate.latitude, longitude: anno.coordinate.longitude)
            if a.distance(from: b) > 30 {
                centerOn(anno.coordinate, mapView: mapView, animated: true)
                // 팔로우 이동으로 화면이 크게 바뀌었으면 정류장 자동 갱신
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.parent.vm.onRegionCommitted(mapView.region)
                }
            }
        }

        // 뷰 팩토리
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let s = annotation as? BusStopAnnotation {
        DBG.map.log("🧷 make stop view id=\(s.stop.id, privacy: .public) name=\(s.stop.name, privacy: .public)")

                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "stop", for: s) as! MKMarkerAnnotationView
                v.clusteringIdentifier = "stop"
                v.glyphText = "🚏"
                v.markerTintColor = (parent.vm.highlightedStopId == s.stop.id) ? .systemYellow : .systemRed
                v.titleVisibility = .visible
                v.subtitleVisibility = .hidden
                v.displayPriority = .required
                v.layer.zPosition = 100
                return v
            } else if let b = annotation as? BusAnnotation {
        DBG.map.log("🚌 make bus view id=\(b.id, privacy: .public)")

                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bus", for: b) as! BusMarkerView
                let isFollowed = (parent.vm.followBusId == b.id)
                v.clusteringIdentifier = isFollowed ? "bus-\(b.id)" : "bus" // 클러스터 예외
                v.configureTint(isFollowed: isFollowed)
                v.displayPriority = .required
                v.layer.zPosition = 100
                v.canShowCallout = true
                let btn = UIButton(type: .system)
                btn.setTitle(isFollowed ? "해제" : "추적", for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                v.rightCalloutAccessoryView = btn
                v.updateAlwaysOnBubble()

                // CRASH FIX: 여기서 다른 annotation에 접근/열거 금지
                // (겹침 해소는 배치 후 safeDeconflictAll에서 수행)

                return v
            } else if let cluster = annotation as? MKClusterAnnotation {
                let cv = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: cluster
                )
                cv.layer.zPosition = 80
                return cv
            }
            return nil
        }

        // ClusteredMapView.Coord
        /// 정류소와 매우 가까울 때, '좌표'는 건드리지 않고 '뷰'만 살짝 비켜놓아 겹침을 피한다.
        /// - 주의: centerOffset(포인트 단위)을 쓰므로 추적/계산/클러스터링에 영향 없음.
        private func applyVisualDeconflictIfNearStop(_ mapView: MKMapView,
                                                    view v: MKAnnotationView,
                                                    bus: BusAnnotation) {
            // 기본 오프셋(버스 마커의 원래 시각적 위치)
            let defaultOffset = CGPoint(x: 0, y: -10)

            // 맵에 현재 보이는 정류소들 스냅샷
            let stopAnnos = mapView.annotations.compactMap { $0 as? BusStopAnnotation }
            guard let nearest = stopAnnos.min(by: { lhs, rhs in
                let dl = CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude)
                    .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                let dr = CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude)
                    .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))
                return dl < dr
            }) else {
                // 정류소가 없으면 기본값 유지
                v.centerOffset = defaultOffset
                return
            }

            // 버스-정류소 거리(m)
            let dist = CLLocation(latitude: nearest.coordinate.latitude, longitude: nearest.coordinate.longitude)
                .distance(from: CLLocation(latitude: bus.coordinate.latitude, longitude: bus.coordinate.longitude))

            // 임계값(겹친다고 보기): 8m
            let threshold: CLLocationDistance = 8.0
            guard dist <= threshold else {
                v.centerOffset = defaultOffset
                return
            }

            // 가까우면 '뷰'를 살짝(포인트 기준) 비켜놓는다.
            // 지도 스케일을 몰라도 시각적으로 충분한 미세 오프셋: 6pt 정도
            // 정류소→버스 방향을 대략 반영하여 살짝 치우치게 표시
            let dx = bus.coordinate.longitude - nearest.coordinate.longitude
            let dy = bus.coordinate.latitude  - nearest.coordinate.latitude
            let mag = max(1e-9, sqrt(dx*dx + dy*dy))
            let ux = dx / mag
            let uy = dy / mag

            // 지도의 위쪽(-y)이 시각적으로 위로 올라가므로 y는 반대로 준다
            let bump: CGFloat = 6.0
            let px = CGFloat(ux) * bump
            let py = CGFloat(-uy) * bump

            v.centerOffset = CGPoint(x: defaultOffset.x + px, y: defaultOffset.y + py)
        }


        
        // **탭 토글**: 같은 버스를 다시 누르면 해제, 아니면 추적 시작
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let bus = view.annotation as? BusAnnotation else { return }

            let already = (parent.vm.followBusId == bus.id)
            if already {
                // ▶ 추적 해제
                parent.vm.followBusId = nil
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
            } else {
                // ▶ 추적 시작
                parent.vm.followBusId = bus.id
                if parent.vm.stickToFollowedBus {
                    follow(bus, on: mapView)
                }

                if let mv = view as? BusMarkerView {
                    mv.configureTint(isFollowed: true)
                    mv.updateAlwaysOnBubble()
                }

                // 1) 트레일 시작
                parent.vm.startTrail(for: bus.id, seed: bus.coordinate)

                // 2) 미래 경로: 이전 것 제거 → 임시 폴백 → 메타 되면 진짜 라인으로 교체
                parent.vm.clearFutureRoute()

                // (a) 임시 폴백 직선 빨간선
                parent.vm.setTemporaryFutureRouteFromBus(busId: bus.id, coordinate: bus.coordinate)
                self.updateFutureRouteOverlay(mapView)

                // (b) 메타 확보 시도 → ✅ 여기 넣기
                if let rid = parent.vm.routeId(forRouteNo: bus.routeNo) {
                    parent.vm.ensureRouteMetaWithRetry(routeId: rid)
                    parent.vm.trySetFutureRouteImmediately(for: bus)
                    self.updateFutureRouteOverlay(mapView)
                }

                // 3) 다음 정류장 하이라이트 즉시 반영
                if let live = parent.vm.buses.first(where: { $0.id == bus.id }) {
                    parent.vm.updateHighlightStop(for: live)
                    self.recolorStops(mapView)
                }

                // 노선 메타 프리페치(성공하면 임시 빨간선이 자동 교체됨)
                Task { await self.parent.vm.onBusSelected(bus) }
            }

            // 토글 UX: 선택표시 해제
            mapView.deselectAnnotation(bus, animated: false)
        }




//        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
////            if view is BusMarkerView {
////                UIView.animate(withDuration: 0.2) { view.transform = .identity }
////                // 버튼 라벨은 선택 해제와 무관 (토글은 didSelect/callout에서만)
////            }
//        }

        // 콜아웃 버튼으로도 토글
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView,
                     annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            guard let bus = view.annotation as? BusAnnotation else { return }

            if parent.vm.followBusId == bus.id {
                // ▶ 팔로우 해제
                parent.vm.followBusId = nil
                mapView.deselectAnnotation(bus, animated: true)
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: false) }
                if let mv = view as? BusMarkerView, let btn = mv.rightCalloutAccessoryView as? UIButton {
                    btn.setTitle("추적", for: .normal)
                }

                // ✅ 트레일 종료
                parent.vm.stopTrail()
                parent.vm.clearFutureRoute()          // ✅ 미래 경로 지우기
                    self.updateFutureRouteOverlay(mapView)

                // (선택) 하이라이트 정류장 초기화
                parent.vm.highlightedStopId = nil

            } else {
                // ▶ 팔로우 시작
                parent.vm.followBusId = bus.id
                if parent.vm.stickToFollowedBus {
                    follow(bus, on: mapView)
                }
                if let mv = view as? BusMarkerView { mv.configureTint(isFollowed: true); mv.updateAlwaysOnBubble() }
                if let mv = view as? BusMarkerView, let btn = mv.rightCalloutAccessoryView as? UIButton {
                    btn.setTitle("해제", for: .normal)
                }

                // ✅ 트레일 시작
                parent.vm.startTrail(for: bus.id, seed: bus.coordinate)

                // (선택) 바로 정류장 하이라이트 갱신 안전망
                DispatchQueue.main.async { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.updateFollowTints(mapView)
                }
            }
        }


        // 지도가 움직였을 때: 사용자 제스처가 아니더라도, 팔로우 중이면 주기적으로 정류장 재로딩
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // CRASH FIX: 내부 열거 직후 연쇄 호출 경합 완화 (0.30s)
            deb.call(after: 0.30) {
                self.parent.vm.onRegionCommitted(mapView.region)
            }
        }

        
        
        // rendererFor overlay
        // ClusteredMapView.Coord
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: line)
            if line.title == "busTrail" {
                r.strokeColor = .systemOrange   // 지나온 경로(주황/노랑계열)
                r.lineWidth = 4
                r.lineJoin = .round
                r.lineCap  = .round
                return r
            } else if line.title == "futureRoute" {
                r.strokeColor = .systemRed      // 앞으로 갈 경로(빨강)
                r.lineWidth = 4
                r.lineJoin = .round
                r.lineCap  = .round
                return r
            } else {
                r.strokeColor = .systemGray
                r.lineWidth = 3
                return r
            }
        }


        
        
        

        // ClusteredMapView.Coord
        func recolorStops(_ mapView: MKMapView) {
            let targetId = parent.vm.highlightedStopId
            for a in mapView.annotations {
                guard let s = a as? BusStopAnnotation,
                      let v = mapView.view(for: s) as? MKMarkerAnnotationView else { continue }
                v.markerTintColor = (s.stop.id == targetId) ? .systemYellow : .systemRed
            }
        }



        // 트레일 업데이트 유틸
        func updateTrailOverlay(_ mapView: MKMapView) {
            // 기존 트레일 제거
            let olds = mapView.overlays.filter { ($0 as? MKPolyline)?.title == "busTrail" }
            mapView.removeOverlays(olds)
            // 새 트레일 추가
            if let line = parent.vm.trail.polyline() {
                mapView.addOverlay(line)
            }
        }


    }
}

final class Debouncer {
    private var work: DispatchWorkItem?
    func call(after sec: Double, _ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }
}

// MARK: - Location
final class LocationAuth: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    override init() { super.init(); mgr.delegate = self }
    func requestWhenInUse() { mgr.requestWhenInUseAuthorization() }
}

// MARK: - Screen
struct BusMapScreen: View {

    @StateObject private var vm = MapVM()
    @StateObject private var loc = LocationAuth()
    @State private var recenterRequest = false
    
    @State private var showBanner = false     // 노출 여부
    @State private var debugText = ""
        @State private var bannerMounted = false
    var body: some View {
        ZStack {
            ClusteredMapView(vm: vm, recenterRequest: $recenterRequest)
                .ignoresSafeArea()
                .task {
                    loc.requestWhenInUse()
                    await vm.reload(center: .init(latitude: 37.5665, longitude: 126.9780))
                }

            // 내 위치 버튼
            // 내 위치 버튼
            Button {
                loc.requestWhenInUse()
                recenterRequest = true
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .bold))
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(radius: 3)
            }
            .padding(.top, 24)        // 🔼 상단 여백
            .padding(.trailing, 16)   // 🔼 오른쪽 여백
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) // ⬅️ 상단 우측 고정

        }
        // 고정 “추적 중” 배지
        .overlay(alignment: .topLeading) {
            TrackingBadgeView(vm: vm)
                .padding(.top, 8)
                .padding(.leading, 8)
                .padding(.trailing, 8)
        }
.overlay(alignment: .topLeading) { DebugHUD(vm: vm) }

        
        // BusMapScreen.body 에 이미 있는 overlay들 아래/근처에 추가
        // BusMapScreen body의 overlay들 아래에 추가
        .overlay(alignment: .bottomLeading) {
            UpcomingPanelView(vm: vm)
                .padding(.leading, 8)
                .padding(.bottom, 12)
        }


        // ✅ 상단 배너 (노치/상단바와 겹치지 않음)
        // 🔽 레이아웃에 영향 주지 않는 오버레이로 하단에 배너 고정
        .safeAreaInset(edge: .top)  {
                AdFitVerboseBannerView(
                    clientId: "DAN-0pxnvDh8ytVm0EsZ",
                    adUnitSize: "320x50",
                    timeoutSec: 8,
                    maxRetries: 2
                ) { event in
                    switch event {
                    case .begin(let n):  debugText = "BEGIN \(n)"
                    case .willLoad:      debugText = "WILL_LOAD"
                    case .success(let ms):
                        showBanner = true          // ✅ 성공 시 보이기
                        debugText = "SUCCESS \(ms)ms"
                    case .fail(let err, let n):
                        showBanner = false         // 실패 시 숨기기
                        debugText = "FAIL(\(n)): \(err.localizedDescription)"
                    case .timeout(let sec, let n):
                        showBanner = false
                        debugText = "TIMEOUT \(sec)s (attempt \(n))"
                    case .retryScheduled(let after, let next):
                        debugText = "RETRY in \(after)s → \(next)"
                    case .disposed:
                        debugText = "disposed"
                    }
                }
                .frame(width: 320, height: 50)     // 뷰 자체는 실제 크기 유지
                .opacity(showBanner ? 1 : 0)       // 🔸 화면에서는 숨김/표시만 제어
                .allowsHitTesting(showBanner)
                .padding(.bottom, 8)
                .animation(.easeInOut(duration: 0.2), value: showBanner)
                }
    }
}
/// JSON에서 item이 단일 객체이든 배열이든 모두 수용


/// items가 `{ "item": ... }` 이거나 `""`(빈 문자열) 이거나 `null` 이어도 OK
/// 배열/단일/빈문자열 모두 수용하는 items 디코더



// 고정 추적 배지
struct TrackingBadgeView: View {
    @ObservedObject var vm: MapVM

    var body: some View {
        if let fid = vm.followBusId,
           let info = vm.buses.first(where: { $0.id == fid }) {
            HStack(spacing: 8) {
                Text("🎯 추적 중").font(.caption).bold()
                Text("\(info.routeNo) • \(info.nextStopName ?? "다음 정류장 미정")")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { vm.followBusId = nil }
                } label: {
                    Text("해제").font(.caption2).bold()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("추적 중 배지")
        }
    }
}


// 새 파일 or MapVM 내부
import MapKit

/// 과거 이동경로(트레일) 저장소
final class BusTrailStore {

    // 최근 팔로우 중인 버스 id (옵션)
    private(set) var currentBusId: String?

    // 경로 좌표
    private var points: [CLLocationCoordinate2D] = []

    // 성능/메모리 보호
    private let maxCount: Int = 800        // 최대 점수 (적당히 조절)
    private let minStepMeters: CLLocationDistance = 6   // 일정 거리 이상 이동했을 때만 기록

    // 시작/중지
    func start(id: String, seed: CLLocationCoordinate2D?) {
        currentBusId = id
        points.removeAll()
        if let s = seed, CLLocationCoordinate2DIsValid(s) {
            points.append(s)
        }
    }

    func stop() {
        currentBusId = nil
        points.removeAll()
    }

    // 위치 추가(너무 촘촘하면 생략)
    func appendIfNeeded(_ c: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(c) else { return }
        if let last = points.last {
            let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            // 너무 가까우면 패스
            if d < minStepMeters { return }
        }
        points.append(c)
        if points.count > maxCount {
            points.removeFirst(points.count - maxCount)
        }
    }

    // MapKit 오버레이로 만들기
    func polyline() -> MKPolyline? {
        guard points.count >= 2 else { return nil }
        let line = MKPolyline(coordinates: points, count: points.count)
        line.title = "busTrail"   // ✅ renderer에서 이 타이틀로 주황색 처리
        return line
    }
}


// 새 파일로 두거나, 같은 파일 하단에 추가

import SwiftUI

struct UpcomingStopsPanel: View {
    @ObservedObject var vm: MapVM
    let maxCount: Int = 7

    // 계산 프로퍼티로 분리 (ViewBuilder 바깥)
    // 기존
    // private var items: [UpcomingStopETA] {
    //     guard let fid = vm.followBusId else { return [] }
    //     return vm.upcomingStops(for: fid, maxCount: maxCount)
    // }

    // 변경
    private var items: [UpcomingStopETA] {
        guard let fid = vm.followBusId else { return [] }
        let arr = vm.upcomingStops(for: fid, maxCount: maxCount)
        var seen = Set<String>()
        // ▶ id 기준, 최초 1회만 통과 (안정적인 순서 유지)
        return arr.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Group {
            if vm.followBusId != nil {
                if items.isEmpty {
                    // 메타/경로 로딩 중인 상태도 패널이 보이게
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("경로 불러오는 중…")
                            .font(.caption)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 2)
                    .frame(maxWidth: 260)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("🧭 다음 정류장").font(.caption).bold()
                            Text("(\(items.count))").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(items) { it in
                            HStack(spacing: 10) {
                                Text(it.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text("\(it.etaMin)분")
                                    .font(.caption).monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 2)
                    .frame(maxWidth: 260)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.bottom, 10)
        .allowsHitTesting(false)     // 맵 제스처 방해 X
        .transition(.move(edge: .leading).combined(with: .opacity))
        .zIndex(999)                 // 다른 오버레이 위로
    }
}

// 새 파일 또는 같은 파일 하단
struct UpcomingPanelView: View {
    @ObservedObject var vm: MapVM

    var body: some View {
        Group {
            if let fid = vm.followBusId {
                if let live = vm.buses.first(where: { $0.id == fid }) {
                    UpcomingPanelContent(vm: vm, fid: fid, live: live)
                }
            }
        }
    }
}

private struct UpcomingPanelContent: View {
    @ObservedObject var vm: MapVM
    let fid: String
    let live: BusLive

    var body: some View {
        // 목록 생성
        let itemsRaw = vm.upcomingStops(for: fid, maxCount: 7)
        let items: [UpcomingStopETA] = {
            var seen = Set<String>()
            return itemsRaw.filter { seen.insert($0.id).inserted }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("🗺️ \(live.routeNo)")
                    .font(.caption).bold()
                Text(live.nextStopName ?? "다음 정류장 추정중…")
                    .font(.caption)
                    .lineLimit(1)
            }

            ForEach(items, id: \.id) { it in
                HStack {
                    Circle().frame(width: 6, height: 6)
                    Text(it.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(it.etaMin)분").font(.caption2).monospacedDigit()
                }
            }

            if items.isEmpty {
                Text("경로 메타 없음 — 근처/방향 기반으로 추정중")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 2)
        // 빨간 라인 갱신
        .onAppear {
            vm.redrawFutureRouteFromUpcoming(busId: fid, maxCount: 7)
        }
        .onChange(of: vm.upcomingTick) { _ in
            vm.redrawFutureRouteFromUpcoming(busId: fid, maxCount: 7)
        }
        .onChange(of: vm.followBusId) { _ in
            if let fid2 = vm.followBusId {
                vm.redrawFutureRouteFromUpcoming(busId: fid2, maxCount: 7)
            }
        }
        .onChange(of: items.map(\.id).joined(separator: "|")) { _ in
            vm.redrawFutureRouteFromUpcoming(busId: fid, maxCount: 7)
        }
    }
}
struct DebugHUD: View {
    @ObservedObject var vm: MapVM
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stops: \(vm.stops.count)").font(.caption2).bold()
            Text("Buses: \(vm.buses.count)").font(.caption2)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 1)
        .padding(.top, 60)
        .padding(.leading, 8)
    }
}

// BusMapScreen overlay에 추가
