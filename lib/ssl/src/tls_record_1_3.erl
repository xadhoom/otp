%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2007-2021. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%

-module(tls_record_1_3).

-include("tls_record.hrl").
-include("tls_record_1_3.hrl").
-include("ssl_internal.hrl").
-include("ssl_alert.hrl").
-include("ssl_cipher.hrl").

%% Encoding 
-export([encode_handshake/2, encode_alert_record/2,
	 encode_data/2]).
-export([encode_plain_text/3]).

%% Decoding
-export([decode_cipher_text/2]).

%%====================================================================
%% Encoding
%%====================================================================

%%--------------------------------------------------------------------
-spec encode_handshake(iolist(), ssl_record:connection_states()) ->
			      {iolist(), ssl_record:connection_states()}.
%
%% Description: Encodes a handshake message to send on the tls-1.3-socket.
%%--------------------------------------------------------------------
encode_handshake(Frag, #{current_write := #{max_fragment_length := MaxFragmentLength}} =
                     ConnectionStates) ->
    MaxLength = if is_integer(MaxFragmentLength) ->
                        MaxFragmentLength;
                   true ->
                        %% TODO: Consider padding here
                        ?MAX_PLAIN_TEXT_LENGTH
                end,
    case iolist_size(Frag) of
	N  when N > MaxLength ->
	    Data = tls_record:split_iovec(erlang:iolist_to_iovec(Frag), MaxLength),
	    encode_iolist(?HANDSHAKE, Data, ConnectionStates);
	_  ->
	    encode_plain_text(?HANDSHAKE, Frag, ConnectionStates)
    end.

%%--------------------------------------------------------------------
-spec encode_alert_record(#alert{}, ssl_record:connection_states()) ->
				 {iolist(), ssl_record:connection_states()}.
%%
%% Description: Encodes an alert message to send on the ssl-socket.
%%--------------------------------------------------------------------
encode_alert_record(#alert{level = Level, description = Description},
                    ConnectionStates) ->
    encode_plain_text(?ALERT, <<?BYTE(Level), ?BYTE(Description)>>,
		      ConnectionStates).
%%--------------------------------------------------------------------
-spec encode_data(iolist(), ssl_record:connection_states()) ->
			 {iolist(), ssl_record:connection_states()}.
%%
%% Description: Encodes data to send on the ssl-socket.
%%--------------------------------------------------------------------
encode_data(Frag, #{current_write := #{max_fragment_length := MaxFragmentLength}} =
                     ConnectionStates) ->
    MaxLength = if is_integer(MaxFragmentLength) ->
                        MaxFragmentLength;
                   true ->
                        ?MAX_PLAIN_TEXT_LENGTH
                end,
    Data = tls_record:split_iovec(Frag, MaxLength),
    encode_iolist(?APPLICATION_DATA, Data, ConnectionStates).

encode_plain_text(Type, Data0, #{current_write := Write0} = ConnectionStates) ->
    PadLen = 0, %% TODO where to specify PadLen?
    Data = inner_plaintext(Type, Data0, PadLen),
    CipherFragment = encode_plain_text(Data, Write0),
    {CipherText, Write} = encode_tls_cipher_text(CipherFragment, Write0),
    {CipherText, ConnectionStates#{current_write => Write}}.

encode_iolist(Type, Data, ConnectionStates0) ->
    {ConnectionStates, EncodedMsg} =
        lists:foldl(fun(Text, {CS0, Encoded}) ->
			    {Enc, CS1} =
				encode_plain_text(Type, Text, CS0),
			    {CS1, [Enc | Encoded]}
		    end, {ConnectionStates0, []}, Data),
    {lists:reverse(EncodedMsg), ConnectionStates}.

%%====================================================================
%% Decoding
%%====================================================================

%%--------------------------------------------------------------------
-spec decode_cipher_text(#ssl_tls{}, ssl_record:connection_states()) ->
				{#ssl_tls{} | trial_decryption_failed,
                                 ssl_record:connection_states()}| #alert{}.
%%
%% Description: Decode cipher text, use legacy type ssl_tls instead of tls_cipher_text
%% in decoding context so that we can reuse the code from earlier versions. 
%%--------------------------------------------------------------------
decode_cipher_text(#ssl_tls{type = ?OPAQUE_TYPE,
                            version = ?LEGACY_VERSION,
                            fragment = CipherFragment},
		   #{current_read :=
			 #{sequence_number := Seq,
                           cipher_state := #cipher_state{key = Key,
                                                         iv = IV,
                                                         tag_len = TagLen},
			   security_parameters :=
			       #security_parameters{
				  cipher_type = ?AEAD,
                                  bulk_cipher_algorithm =
                                      BulkCipherAlgo},
                           max_early_data_size := MaxEarlyDataSize0,
                           trial_decryption := TrialDecryption,
                           early_data_limit := EarlyDataLimit
			  } = ReadState0} = ConnectionStates0) ->
    case decipher_aead(CipherFragment, BulkCipherAlgo, Key, Seq, IV, TagLen) of
	#alert{} when TrialDecryption =:= true andalso
                      MaxEarlyDataSize0 > 0 -> %% Trial decryption
            trial_decrypt(ConnectionStates0, ReadState0, MaxEarlyDataSize0,
                          BulkCipherAlgo, CipherFragment);
	#alert{} = Alert ->
	    Alert;
        PlainFragment0 when EarlyDataLimit =:= true andalso
                            MaxEarlyDataSize0 > 0 ->
            PlainFragment = remove_padding(PlainFragment0),
            process_early_data(ConnectionStates0, ReadState0, MaxEarlyDataSize0, Seq,
                               BulkCipherAlgo, CipherFragment, PlainFragment);
	PlainFragment0 ->
            PlainFragment = remove_padding(PlainFragment0),
	    ConnectionStates =
                ConnectionStates0#{current_read =>
                                       ReadState0#{sequence_number => Seq + 1}},
	    {decode_inner_plaintext(PlainFragment), ConnectionStates}
    end;


%% RFC8446 - TLS 1.3 (OpenSSL compatibility)
%% Handle unencrypted Alerts from openssl s_client when server's
%% connection states are already stepped into traffic encryption.
%% (E.g. openssl s_client receives a CertificateRequest with
%% a signature_algorithms_cert extension that does not contain
%% the signature algorithm of the client's certificate.)
decode_cipher_text(#ssl_tls{type = ?ALERT,
                            version = ?LEGACY_VERSION,
                            fragment = <<2,47>>},
		   ConnectionStates0) ->
    {#ssl_tls{type = ?ALERT,
              version = {3,4}, %% Internally use real version
              fragment = <<2,47>>}, ConnectionStates0};
%% TLS 1.3 server can receive a User Cancelled Alert when handshake is
%% paused and then cancelled on the client side.
decode_cipher_text(#ssl_tls{type = ?ALERT,
                            version = ?LEGACY_VERSION,
                            fragment = <<2,90>>},
		   ConnectionStates0) ->
    {#ssl_tls{type = ?ALERT,
              version = {3,4}, %% Internally use real version
              fragment = <<2,90>>}, ConnectionStates0};
%% RFC8446 - TLS 1.3
%% D.4.  Middlebox Compatibility Mode
%%    -  If not offering early data, the client sends a dummy
%%       change_cipher_spec record (see the third paragraph of Section 5)
%%       immediately before its second flight.  This may either be before
%%       its second ClientHello or before its encrypted handshake flight.
%%       If offering early data, the record is placed immediately after the
%%       first ClientHello.
decode_cipher_text(#ssl_tls{type = ?CHANGE_CIPHER_SPEC,
                            version = ?LEGACY_VERSION,
                            fragment = <<1>>},
		   ConnectionStates0) ->
    {#ssl_tls{type = ?CHANGE_CIPHER_SPEC,
              version = {3,4}, %% Internally use real version
              fragment = <<1>>}, ConnectionStates0};
decode_cipher_text(#ssl_tls{type = Type,
                            version = ?LEGACY_VERSION,
                            fragment = CipherFragment},
		   #{current_read :=
			 #{security_parameters :=
			       #security_parameters{
                                  cipher_suite = ?TLS_NULL_WITH_NULL_NULL}
			  }} = ConnnectionStates0) ->
    {#ssl_tls{type = Type,
              version = {3,4}, %% Internally use real version
              fragment = CipherFragment}, ConnnectionStates0};
decode_cipher_text(#ssl_tls{type = Type}, _) ->
    %% Version mismatch is already asserted
    ?ALERT_REC(?FATAL, ?BAD_RECORD_MAC, {record_type_mismatch, Type}).



%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
trial_decrypt(ConnectionStates0, ReadState0, MaxEarlyDataSize0,
              BulkCipherAlgo, CipherFragment) ->
    MaxEarlyDataSize = update_max_early_date_size(MaxEarlyDataSize0, BulkCipherAlgo, CipherFragment),
    ConnectionStates =
        ConnectionStates0#{current_read =>
                               ReadState0#{max_early_data_size => MaxEarlyDataSize}},
    if MaxEarlyDataSize < 0 ->
            %% More early data is trial decrypted as the configured limit
            ?ALERT_REC(?FATAL, ?BAD_RECORD_MAC, decryption_failed);
       true ->
            {trial_decryption_failed, ConnectionStates}
    end.

process_early_data(ConnectionStates0, ReadState0, _MaxEarlyDataSize0, Seq,
                   _BulkCipherAlgo, _CipherFragment, PlainFragment)
  when PlainFragment =:= <<5,0,0,0,22>> ->
    %% struct {
    %%     opaque content[TLSPlaintext.length];    <<5,0,0,0>> - 5 = EndOfEarlyData
    %%                                                           0 = (uint24) size
    %%     ContentType type;                       <<22>> - Handshake
    %%     uint8 zeros[length_of_padding];         <<>> - no padding
    %% } TLSInnerPlaintext;
    %% EndOfEarlyData should not be counted into early data
    ConnectionStates =
        ConnectionStates0#{current_read =>
                               ReadState0#{sequence_number => Seq + 1}},
    {decode_inner_plaintext(PlainFragment), ConnectionStates};
process_early_data(ConnectionStates0, ReadState0, MaxEarlyDataSize0, Seq,
                   BulkCipherAlgo, CipherFragment, PlainFragment) ->
    %% First packet is deciphered anyway so we must check if more early data is received
    %% than the configured limit (max_early_data_size).
    MaxEarlyDataSize =
        update_max_early_date_size(MaxEarlyDataSize0, BulkCipherAlgo, CipherFragment),
    if MaxEarlyDataSize < 0 ->
            %% Too much early data received, send alert unexpected_message
            ?ALERT_REC(?FATAL, ?UNEXPECTED_MESSAGE, too_much_early_data);
       true ->
            ConnectionStates =
                ConnectionStates0#{current_read =>
                                       ReadState0#{sequence_number => Seq + 1,
                                                   max_early_data_size => MaxEarlyDataSize}},
            {decode_inner_plaintext(PlainFragment), ConnectionStates}
    end.

inner_plaintext(Type, Data, Length) ->
    #inner_plaintext{
       content = Data,
       type = Type,
       zeros = zero_padding(Length)
      }.
zero_padding(Length)->
    binary:copy(<<?BYTE(0)>>, Length).

encode_plain_text(#inner_plaintext{
                     content = Data,
                     type = Type,
                     zeros = Zeros
                    }, #{cipher_state := #cipher_state{key= Key,
                                                       iv = IV,
                                                       tag_len = TagLen},
                         sequence_number := Seq,
                         security_parameters :=
                             #security_parameters{
                                cipher_type = ?AEAD,
                                bulk_cipher_algorithm = BulkCipherAlgo}
                        }) ->
    PlainText = [Data, Type, Zeros],
    Encoded = cipher_aead(PlainText, BulkCipherAlgo, Key, Seq, IV, TagLen),
    #tls_cipher_text{opaque_type = 23,  %% 23 (application_data) for outward compatibility
                     legacy_version = {3,3},
                     encoded_record = Encoded};
encode_plain_text(#inner_plaintext{
                     content = Data,
                     type = Type
                    }, #{security_parameters :=
                             #security_parameters{
                                cipher_suite = ?TLS_NULL_WITH_NULL_NULL}
                        }) ->
    %% RFC8446 - 5.1.  Record Layer
    %% When record protection has not yet been engaged, TLSPlaintext
    %% structures are written directly onto the wire.
    #tls_cipher_text{opaque_type = Type,
                      legacy_version = {3,3},
                      encoded_record = Data}.

additional_data(Length) ->
    <<?BYTE(?OPAQUE_TYPE), ?BYTE(3), ?BYTE(3),?UINT16(Length)>>.

%% The per-record nonce for the AEAD construction is formed as
%% follows:
%%
%% 1.  The 64-bit record sequence number is encoded in network byte
%%     order and padded to the left with zeros to iv_length.
%%
%% 2.  The padded sequence number is XORed with either the static
%%     client_write_iv or server_write_iv (depending on the role).
%%
%% The resulting quantity (of length iv_length) is used as the
%% per-record nonce.
nonce(Seq, IV) ->
    Padding = binary:copy(<<0>>, byte_size(IV) - 8),
    crypto:exor(<<Padding/binary,?UINT64(Seq)>>, IV).

cipher_aead(Fragment, BulkCipherAlgo, Key, Seq, IV, TagLen) ->
    AAD = additional_data(erlang:iolist_size(Fragment) + TagLen),
    Nonce = nonce(Seq, IV),
    {Content, CipherTag} =
        ssl_cipher:aead_encrypt(BulkCipherAlgo, Key, Nonce, Fragment, AAD, TagLen),
    <<Content/binary, CipherTag/binary>>.

encode_tls_cipher_text(#tls_cipher_text{opaque_type = Type,
                                        legacy_version = {MajVer, MinVer},
                                        encoded_record = Encoded}, #{sequence_number := Seq} = Write) ->
    Length = erlang:iolist_size(Encoded),
    {[<<?BYTE(Type), ?BYTE(MajVer), ?BYTE(MinVer), ?UINT16(Length)>>, Encoded],
     Write#{sequence_number => Seq +1}}.

decipher_aead(CipherFragment, BulkCipherAlgo, Key, Seq, IV, TagLen) ->
    try
        AAD = additional_data(erlang:iolist_size(CipherFragment)),
        Nonce = nonce(Seq, IV),
        {CipherText, CipherTag} = aead_ciphertext_split(CipherFragment, TagLen),
	case ssl_cipher:aead_decrypt(BulkCipherAlgo, Key, Nonce, CipherText, CipherTag, AAD) of
	    Content when is_binary(Content) ->
		Content;
	    _ ->
                ?ALERT_REC(?FATAL, ?BAD_RECORD_MAC, decryption_failed)
	end
    catch
	_:_ ->
            ?ALERT_REC(?FATAL, ?BAD_RECORD_MAC, decryption_failed)
    end.


aead_ciphertext_split(CipherTextFragment, TagLen)
  when is_binary(CipherTextFragment) ->
    CipherLen = erlang:byte_size(CipherTextFragment) - TagLen,
    <<CipherText:CipherLen/bytes, CipherTag:TagLen/bytes>> = CipherTextFragment,
    {CipherText, CipherTag};
aead_ciphertext_split(CipherTextFragment, TagLen)
  when is_list(CipherTextFragment) ->
    CipherLen = erlang:iolist_size(CipherTextFragment) - TagLen,
    <<CipherText:CipherLen/bytes, CipherTag:TagLen/bytes>> =
        erlang:iolist_to_binary(CipherTextFragment),
    {CipherText, CipherTag}.

decode_inner_plaintext(PlainText) ->
    case binary:last(PlainText) of
        Type when Type =:= ?APPLICATION_DATA orelse
                  Type =:= ?HANDSHAKE orelse
                  Type =:= ?ALERT ->
            #ssl_tls{type = Type,
                     version = {3,4}, %% Internally use real version
                     fragment = init_binary(PlainText)};
        _Else ->
            ?ALERT_REC(?FATAL, ?UNEXPECTED_MESSAGE, empty_alert)
    end.

init_binary(B) ->
    {Init, _} =
        split_binary(B, byte_size(B) - 1),
    Init.

remove_padding(InnerPlainText) ->
    case binary:last(InnerPlainText) of
        0 ->
            remove_padding(init_binary(InnerPlainText));
        _ ->
            InnerPlainText
    end.

update_max_early_date_size(MaxEarlyDataSize, BulkCipherAlgo, CipherFragment) ->
    %% CipherFragment is the binary encoded form of a TLSInnerPlaintext:
    %%
    %% struct {
    %%     opaque content[TLSPlaintext.length];
    %%     ContentType type;
    %%     uint8 zeros[length_of_padding];
    %% } TLSInnerPlaintext;
    %%
    TypeLen = 1,
    PaddingLen = 0, %% TODO Update formula when padding is implemented!
    MaxEarlyDataSize - (byte_size(CipherFragment) - TypeLen - PaddingLen -
                            bca_tag_len(BulkCipherAlgo)).

bca_tag_len(?AES_CCM_8) ->
    8;
bca_tag_len(_) ->
    16.
