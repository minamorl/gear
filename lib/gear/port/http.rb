# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative '../port'

module Gear
  module Port
    # ==================================================================
    # Http — HTTP 要求の port adapter。
    #
    # effect tag :http_request。
    #   payload : { method: enum, url: string, headers?: {string=>string}, body?: string }
    #   result  : { status: integer, headers: {string=>string}, body: string }
    #             生の IO や socket は含めない。ステータス/ヘッダ/本文という
    #             シリアライズ可能な形に畳んで返す (pin journal.records_external_results)。
    #
    # net/http の呼び出しは run の中だけに閉じる。Effect 生成側は純粋
    # (pin port.no_direct_call)。テストでは本物の外部ネットワークを叩かず、
    # ローカル TCPServer を立てるか handler を差し替えて検査する。
    # ==================================================================
    module Http
      TAG = :http_request

      METHODS = {
        GET: Net::HTTP::Get,
        POST: Net::HTTP::Post,
        PUT: Net::HTTP::Put,
        PATCH: Net::HTTP::Patch,
        DELETE: Net::HTTP::Delete,
        HEAD: Net::HTTP::Head
      }.freeze

      PAYLOAD = Zeolite.schema(
        method: Zeolite.enum(*METHODS.keys),
        url: :string,
        headers: Zeolite.optional(Zeolite.map_of(:string)),
        body: :string?
      ).named(:HttpRequestPayload)

      RESULT = Zeolite.schema(
        status: :integer,
        headers: Zeolite.map_of(:string),
        body: :string
      ).named(:HttpRequestResult)

      def self.build
        Adapter.new(:http).operation(
          TAG, payload: PAYLOAD, result: RESULT
        ) do |payload|
          perform(payload)
        end
      end

      # 外界を叩く唯一の場所。payload は正規化済みの素 Hash (string key)。
      def self.perform(payload)
        uri = URI.parse(payload['url'])
        klass = METHODS.fetch(payload['method'].to_sym)
        req = klass.new(uri)
        (payload['headers'] || {}).each { |k, v| req[k] = v }
        req.body = payload['body'] if payload['body']

        res = Net::HTTP.start(uri.hostname, uri.port,
                              use_ssl: uri.scheme == 'https') do |http|
          http.request(req)
        end

        {
          'status' => res.code.to_i,
          # ヘッダは string=>string に畳む。多値ヘッダは net/http が
          # ", " 連結した文字列を返すのでそのまま載せる。
          'headers' => res.each_header.to_h,
          'body' => res.body || ''
        }
      end
    end

    # 読み込み時に既定 registry へ登録 (global_reuse)。
    Http::ADAPTER = Http.build
    register(Http::ADAPTER)
  end
end
