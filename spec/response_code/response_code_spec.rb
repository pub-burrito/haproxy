require_relative('../spec_helper')

describe 'response code' do
  before :all do

    @server = Server.new(4001).start

    haproxy_path = ENV['HAPROXY_PATH'] || File.expand_path('../../../', __FILE__) + '/haproxy'
    haproxy_cfg_path = ENV['HAPROXY_CFG_PATH'] || File.expand_path('../', __FILE__) + '/haproxy.cfg'
    @haproxy = Haproxy.new(haproxy_path, haproxy_cfg_path).start(4000)

    @logd = Haproxy::LogDaemon.new(4001).start # we start after haproxy to silence the startup messages

    @r = Requester.new(4000)
  end

  it 'should be 200 on successful response' do
    expect(@r.request(:get, '/').code).to eq(200)
    expect(@r.request(:get, '/?respond_status=404').code).to eq(404)
    expect(@r.request(:get, '/?respond_status=500').code).to eq(500)
  end
  it 'should be 408 on client timeout with incomplete client headers' do
    expect(@r.request(:get, '/', :sleep_headers => 3).code).to eq(408)
  end
  it 'should be 408 on client timeout with incomplete client body' do
    expect(@r.request(:get, '/', :sleep_body => 3, :body => '1234').code).to eq(408)
  end
  it 'should be 504 on server timeout with incomplete server headers' do
    expect(@r.request(:get, '/?sleep_headers=3').code).to eq(504)
  end
  it 'should not return 5XX on client closing connection with incomplete client headers' do
    expect(500..599).to_not include(@r.request(:get, '/', :close_headers => true).code)
  end
  it 'should not return 5XX on client closing connection with incomplete client body' do
    expect(500..599).to_not include(@r.request(:get, '/', :close_body => true, :body => "1234").code)
  end
  it 'should be 502 on server closing connection with incomplete client body' do
    expect(@r.request(:get, '/?close_client_body=true', :sleep_body => 3, :body => "1234").code).to eq(502)
  end
  it 'should be 502 on server closing connection with incomplete server headers' do
    expect(@r.request(:get, '/?close_headers=true').code).to eq(502)
  end
end
