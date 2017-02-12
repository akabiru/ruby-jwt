# frozen_string_literal: true
require 'base64'
require 'openssl'
require 'jwt/decode'
require 'jwt/default_options'
require 'jwt/encode'
require 'jwt/error'
require 'jwt/json'

# JSON Web Token implementation
#
# Should be up to date with the latest spec:
# https://tools.ietf.org/html/rfc7519#section-4.1.5
module JWT
  extend JWT::Json
  include JWT::DefaultOptions

  module_function

  def sign(algorithm, msg, key)
    if %w(HS256 HS384 HS512).include?(algorithm)
      sign_hmac(algorithm, msg, key)
    elsif %w(RS256 RS384 RS512).include?(algorithm)
      sign_rsa(algorithm, msg, key)
    elsif %w(ES256 ES384 ES512).include?(algorithm)
      sign_ecdsa(algorithm, msg, key)
    else
      raise NotImplementedError, 'Unsupported signing method'
    end
  end

  def sign_rsa(algorithm, msg, private_key)
    raise EncodeError, "The given key is a #{private_key.class}. It has to be an OpenSSL::PKey::RSA instance." if private_key.class == String
    private_key.sign(OpenSSL::Digest.new(algorithm.sub('RS', 'sha')), msg)
  end

  def sign_ecdsa(algorithm, msg, private_key)
    key_algorithm = NAMED_CURVES[private_key.group.curve_name]
    if algorithm != key_algorithm
      raise IncorrectAlgorithm, "payload algorithm is #{algorithm} but #{key_algorithm} signing key was provided"
    end

    digest = OpenSSL::Digest.new(algorithm.sub('ES', 'sha'))
    asn1_to_raw(private_key.dsa_sign_asn1(digest.digest(msg)), private_key)
  end

  def verify_rsa(algorithm, public_key, signing_input, signature)
    public_key.verify(OpenSSL::Digest.new(algorithm.sub('RS', 'sha')), signature, signing_input)
  end

  def verify_ecdsa(algorithm, public_key, signing_input, signature)
    key_algorithm = NAMED_CURVES[public_key.group.curve_name]
    if algorithm != key_algorithm
      raise IncorrectAlgorithm, "payload algorithm is #{algorithm} but #{key_algorithm} verification key was provided"
    end

    digest = OpenSSL::Digest.new(algorithm.sub('ES', 'sha'))
    public_key.dsa_verify_asn1(digest.digest(signing_input), raw_to_asn1(signature, public_key))
  end

  def sign_hmac(algorithm, msg, key)
    OpenSSL::HMAC.digest(OpenSSL::Digest.new(algorithm.sub('HS', 'sha')), key, msg)
  end

  def decoded_segments(jwt, key = nil, verify = true, custom_options = {}, &keyfinder)
    raise(JWT::DecodeError, 'Nil JSON web token') unless jwt

    merged_options = DEFAULT_OPTIONS.merge(custom_options)

    decoder = Decode.new jwt, key, verify, merged_options, &keyfinder
    decoder.decode_segments
  end

  def encode(payload, key, algorithm = 'HS256', header_fields = {})
    encoder = Encode.new payload, key, algorithm, header_fields
    encoder.segments
  end

  def decode(jwt, key = nil, verify = true, custom_options = {}, &keyfinder)
    raise(JWT::DecodeError, 'Nil JSON web token') unless jwt

    merged_options = DEFAULT_OPTIONS.merge(custom_options)
    decoder = Decode.new jwt, key, verify, merged_options, &keyfinder
    header, payload, signature, signing_input = decoder.decode_segments
    decode_verify_signature(key, header, payload, signature, signing_input, merged_options, &keyfinder) if verify
    decoder.verify

    raise(JWT::DecodeError, 'Not enough or too many segments') unless header && payload

    [payload, header]
  end

  def decode_verify_signature(key, header, payload, signature, signing_input, options, &keyfinder)
    algo, key = signature_algorithm_and_key(header, payload, key, &keyfinder)

    raise(JWT::IncorrectAlgorithm, 'An algorithm must be specified') unless options[:algorithm]
    raise(JWT::IncorrectAlgorithm, 'Expected a different algorithm') unless algo == options[:algorithm]

    verify_signature(algo, key, signing_input, signature)
  end

  def signature_algorithm_and_key(header, payload, key, &keyfinder)
    if keyfinder
      key = if keyfinder.arity == 2
              yield(header, payload)
            else
              yield(header)
            end
      raise JWT::DecodeError, 'No verification key available' unless key
    end
    [header['alg'], key]
  end

  def verify_signature(algo, key, signing_input, signature)
    verify_signature_algo(algo, key, signing_input, signature)
  rescue OpenSSL::PKey::PKeyError
    raise JWT::VerificationError, 'Signature verification raised'
  ensure
    OpenSSL.errors.clear
  end

  def verify_signature_algo(algo, key, signing_input, signature)
    if %w(HS256 HS384 HS512).include?(algo)
      raise(JWT::VerificationError, 'Signature verification raised') unless secure_compare(signature, sign_hmac(algo, signing_input, key))
    elsif %w(RS256 RS384 RS512).include?(algo)
      raise(JWT::VerificationError, 'Signature verification raised') unless verify_rsa(algo, key, signing_input, signature)
    elsif %w(ES256 ES384 ES512).include?(algo)
      raise(JWT::VerificationError, 'Signature verification raised') unless verify_ecdsa(algo, key, signing_input, signature)
    else
      raise JWT::VerificationError, 'Algorithm not supported'
    end
  end

  # From devise
  # constant-time comparison algorithm to prevent timing attacks
  def secure_compare(a, b)
    return false if a.nil? || b.nil? || a.empty? || b.empty? || a.bytesize != b.bytesize
    l = a.unpack "C#{a.bytesize}"
    res = 0
    b.each_byte { |byte| res |= byte ^ l.shift }
    res.zero?
  end

  def raw_to_asn1(signature, private_key)
    byte_size = (private_key.group.degree + 7) / 8
    r = signature[0..(byte_size - 1)]
    s = signature[byte_size..-1] || ''
    OpenSSL::ASN1::Sequence.new([r, s].map { |int| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(int, 2)) }).to_der
  end

  def asn1_to_raw(signature, public_key)
    byte_size = (public_key.group.degree + 7) / 8
    OpenSSL::ASN1.decode(signature).value.map { |value| value.value.to_s(2).rjust(byte_size, "\x00") }.join
  end

  def base64url_decode(str)
    Decode.base64url_decode(str)
  end

  def base64url_encode(str)
    Base64.encode64(str).tr('+/', '-_').gsub(/[\n=]/, '')
  end
end
