"""Local tests with fake keys and synthetic text; never calls a paid API."""
import copy
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

import server


def request():
    return {'version': 1, 'reference_time': '2026-10-27T10:00:00Z', 'time_zone': 'Asia/Shanghai',
            'turns': [{'id': 'ABCDEF00-0000-4000-8000-000000000001', 'origin': 'demonstration',
                       'text': '演示：明天去二楼，带12元，电话12345678。'}]}


def result():
    return {'summary': '演示约定', 'replies': ['请再确认时间。'], 'candidates': [
        {'kind': 'amount', 'value': '12', 'source_id': request()['turns'][0]['id'], 'quote': '带12元', 'currency': 'CNY'}]}


class ValidationTests(unittest.TestCase):
    def test_input_rejects_bad_sources_duplicate_ids_and_timezone(self):
        self.assertEqual(server.validate_input(request()), request())
        for change in [('version', True), ('turns', []), ('time_zone', 'not-a-time-zone')]:
            bad = request(); bad[change[0]] = change[1]
            with self.assertRaises(server.Invalid): server.validate_input(bad)
        bad = request(); other = copy.deepcopy(bad['turns'][0]); other['id'] = other['id'].lower(); bad['turns'].append(other)
        with self.assertRaises(server.Invalid): server.validate_input(bad)

    def test_result_requires_exact_quote_supported_number_and_digits(self):
        self.assertEqual(server.validate_result(result(), request())['candidates'][0]['value'], '12')
        for key, value in [('value', '120'), ('quote', '不是原文'), ('source_id', 'missing')]:
            bad = result(); bad['candidates'][0][key] = value
            with self.assertRaises(server.Invalid): server.validate_result(bad, request())
        bad = result(); bad['candidates'] = [{'kind': 'phone', 'value': '87654321',
            'source_id': request()['turns'][0]['id'], 'quote': '电话12345678'}]
        with self.assertRaises(server.Invalid): server.validate_result(bad, request())

    def test_currency_binds_to_its_own_number_and_accepts_equal_decimal_formats(self):
        for quote, value, currency in [('12美元', '12','USD'), ('12元人民币','12.00','CNY'),
                ('USD 1,200.50','1200.50','USD'), ('人民币12元','12','CNY'), ('12美元和20元人民币','20','CNY'),
                ('12日元','12','JPY'), ('港币12','12','HKD')]:
            self.assertTrue(server.grounded_amount(value,currency,quote), quote)
        for quote, value, currency in [('12美元','12','CNY'), ('12美元和20元人民币','12','CNY'),
                ('12日元','12','CNY'), ('12港元','12','CNY'), ('12欧元','12','CNY'),
                ('USD12元','12','USD'), ('1,2元','12','CNY'), ('-12元','12','CNY'), ('12.345元','12.34','CNY')]:
            self.assertFalse(server.grounded_amount(value,currency,quote), quote)

    def test_action_claims_are_removed_with_an_explicit_count(self):
        data=result(); data['replies']=['已保存这些信息。','会提醒你带证件。','请再确认一下时间。']
        clean=server.validate_result(data,request())
        self.assertEqual(clean['replies'],['请再确认一下时间。']);self.assertEqual(clean['suppressed_replies'],2)

    def test_same_number_in_two_currencies_is_not_a_duplicate(self):
        data=request();data['turns'][0]['text']='演示：12美元和12元人民币。'
        response=result();response['candidates'][0]['quote']='12元人民币'
        other=copy.deepcopy(response['candidates'][0]);other.update(currency='USD',quote='12美元')
        response['candidates'].append(other)
        self.assertEqual(len(server.validate_result(response,data)['candidates']),2)
        response['candidates'].append(other)
        with self.assertRaises(server.Invalid):server.validate_result(response,data)

    def test_upstream_incomplete_or_oversized_output_is_rejected(self):
        for body in [json.dumps({'choices':[{'finish_reason':'length', 'message':{'content': json.dumps(result())}}]}).encode(),
                     b'x' * (server.MAX_BODY+1)]:
            with patch.object(server.urllib.request, 'urlopen', return_value=io.BytesIO(body)):
                with self.assertRaises(server.Invalid): server.call_deepseek(request(), 'fake-key', 'test-model')

    def test_only_selected_payload_is_sent_once_with_a_timeout(self):
        upstream = {'choices':[{'finish_reason':'stop', 'message':{'content': json.dumps(result())}}]}
        with patch.object(server.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(upstream).encode())) as call:
            server.call_deepseek(request(), 'fake-key', 'test-model')
        call.assert_called_once()
        sent = json.loads(call.call_args.args[0].data)
        self.assertEqual(json.loads(sent['messages'][1]['content']), request())
        self.assertEqual(call.call_args.kwargs['timeout'], 40)

    def test_questions_require_a_real_source_and_exact_quote(self):
        response=result();response['questions']=[{'kind':'time','question':'请确认完整日期？',
            'source_id':request()['turns'][0]['id'],'quote':'明天去二楼'}]
        self.assertEqual(len(server.validate_result(response,request())['questions']),1)
        response['questions'][0]['quote']='原文没有说过'
        with self.assertRaises(server.Invalid):server.validate_result(response,request())

    def test_translation_validates_origin_language_size_and_does_not_expose_key(self):
        data={'version':1,'source_id':request()['turns'][0]['id'],'target':'en','origin':'imageText','text':'演示：费用12美元。'}
        self.assertEqual(server.validate_translation_input(data),data)
        with patch.object(server,'provider_json',return_value={'text':'Demo: the fee is 12 USD.'}) as call:
            translated=server.call_translate(data,'fake-key','test-model')
        self.assertEqual(translated['source_id'],data['source_id']);self.assertEqual(translated['target'],'en')
        self.assertNotIn('key',translated);call.assert_called_once()
        for field,value in [('target','invalid'),('text','字'*1501),('origin','unknown')]:
            bad=copy.deepcopy(data);bad[field]=value
            with self.assertRaises(server.Invalid):server.validate_translation_input(bad)

    def test_case_plan_is_opt_in_and_all_rows_reference_real_selected_text(self):
        data=request();data['include_case_plan']=True
        plan={'title':'演示事务','items':[{'kind':'material','value':'带12元','basis':'stated','source_id':data['turns'][0]['id'],'quote':'带12元'}]}
        response=result();response['case_plan']=plan
        self.assertEqual(server.validate_result(response,data)['case_plan']['title'],'演示事务')
        without=request()
        with self.assertRaises(server.Invalid):server.validate_result(response,without)
        response['case_plan']['items'][0]['quote']='不存在'
        with self.assertRaises(server.Invalid):server.validate_result(response,data)
        data['include_case_plan']='true'
        with self.assertRaises(server.Invalid):server.validate_input(data)

    def test_case_plan_rejects_guessed_materials_duplicates_and_completed_actions(self):
        data=request();data['include_case_plan']=True
        base={'title':'演示事务','items':[{'kind':'material','value':'12元','basis':'stated','source_id':data['turns'][0]['id'],'quote':'带12元'}]}
        for key,value in [('basis','suggested'),('source_id','unknown'),('value','已完成报名'),('value','护照')]:
            bad=copy.deepcopy(base);bad['items'][0][key]=value
            with self.assertRaises(server.Invalid):server.validate_case_plan(bad,data)
        duplicate=copy.deepcopy(base);duplicate['items']*=2
        with self.assertRaises(server.Invalid):server.validate_case_plan(duplicate,data)

    def test_one_generation_can_return_information_and_case_plan(self):
        data=request();data['include_case_plan']=True
        response=result();response['case_plan']={'title':'演示事务','items':[]}
        upstream={'choices':[{'finish_reason':'stop','message':{'content':json.dumps(response)}}]}
        with patch.object(server.urllib.request,'urlopen',return_value=io.BytesIO(json.dumps(upstream).encode())) as call:
            output=server.call_deepseek(data,'fake-key','test-model')
        call.assert_called_once();sent=json.loads(call.call_args.args[0].data)
        self.assertEqual(sent['max_tokens'],3000);self.assertEqual(len(output['candidates']),1);self.assertEqual(output['case_plan']['items'],[])


class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings = {'key':'fake-not-a-secret', 'token':'local-test-pairing-1234567890123456', 'model':'test-model'}
        cls.proxy = server.make_server(port=0, settings=cls.settings)
        cls.thread = threading.Thread(target=cls.proxy.serve_forever, daemon=True); cls.thread.start()
        cls.base = 'http://127.0.0.1:%s' % cls.proxy.server_port

    @classmethod
    def tearDownClass(cls):
        cls.proxy.shutdown(); cls.proxy.server_close(); cls.thread.join()

    def setUp(self):
        self.proxy.calls.clear()

    def send(self, path, payload=None, authorized=True):
        headers = {'Authorization':'Bearer '+self.settings['token']} if authorized else {}
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(self.base+path, data=data, headers=headers)
        try:
            response = urllib.request.urlopen(req, timeout=2)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def test_health_authentication_and_no_conversation_upload(self):
        with patch.object(server, 'call_deepseek') as call:
            status, data = self.send('/health')
            self.assertEqual(status, 200); self.assertTrue(data['configured']); call.assert_not_called()
            status, _ = self.send('/health', authorized=False); self.assertEqual(status, 401)

    def test_request_validation_and_rate_limit_happen_before_provider(self):
        with patch.object(server, 'call_deepseek', return_value=result()) as call:
            status, _ = self.send('/v1/organize', {}, authorized=True); self.assertEqual(status, 400)
            status, _ = self.send('/v1/organize', request(), authorized=False); self.assertEqual(status, 401)
            call.assert_not_called()
            for _ in range(6): self.assertEqual(self.send('/v1/organize', request())[0], 200)
            self.assertEqual(self.send('/v1/organize', request())[0], 429); self.assertEqual(call.call_count, 6)

    def test_provider_error_and_timeout_return_no_suggestions_or_secrets(self):
        failure = urllib.error.HTTPError('https://api.deepseek.com/chat/completions', 402, 'balance', {}, None)
        with patch.object(server, 'call_deepseek', side_effect=failure):
            status, data = self.send('/v1/organize', request())
            self.assertEqual(status, 502); self.assertEqual(data, {'error':'provider_balance'})
        with patch.object(server, 'call_deepseek', side_effect=TimeoutError('synthetic failure')) as call:
            status, data = self.send('/v1/organize', request())
            self.assertEqual(status, 502); self.assertEqual(data, {'error':'provider_invalid_or_unavailable'}); call.assert_called_once()

    def test_nonlocal_listener_requires_https(self):
        with self.assertRaises(RuntimeError): server.make_server(host='0.0.0.0', port=0, settings=self.settings)

    def test_translation_route_accepts_four_languages_but_never_organizes_implicitly(self):
        data={'version':1,'source_id':request()['turns'][0]['id'],'target':'en','origin':'demonstration','text':'演示：请写下时间。'}
        with patch.object(server,'call_translate',return_value={'text':'Demo translation'}) as translate, patch.object(server,'call_deepseek') as organize:
            for language in ['zh-Hans','en','ja','ko']:
                data['target']=language
                status,response=self.send('/v1/translate',data)
                self.assertEqual(status,200);self.assertEqual(response['provider'],'DeepSeek')
            self.assertEqual(translate.call_count,4);organize.assert_not_called()


if __name__ == '__main__':
    unittest.main()
